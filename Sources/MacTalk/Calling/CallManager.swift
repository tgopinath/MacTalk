import AppKit
import Foundation
import MacTalkCore
import Observation
import Supabase
@preconcurrency import WebRTC

/// Drives one call at a time from "Call" (or an incoming ring) to hang-up.
///
/// Flow
/// 1. Caller: `start_call` RPC (server checks friendship, blocking, presence, busy, rate
///    limit and races) → row inserted with status `ringing`.
/// 2. Callee: receives the row via Realtime (or the heartbeat fallback) → ringtone +
///    bottom-right alert. No microphone is opened while ringing.
/// 3. Callee accepts → `answer_call` → both sides open WebRTC. The caller sends the SDP
///    offer, the callee answers, ICE candidates trickle through `call_signals`.
/// 4. Either side ends → `end_call`; the other side sees the status change.
@MainActor @Observable
final class CallManager {
    struct Session {
        var callID: UUID?
        let direction: CallDirection
        let peer: CallPeer
        var machine: CallStateMachine
        var expiresAt: Date?
        var connectedAt: Date?
        var isMuted = false
        var quality: ConnectionQuality = .unknown
        var micDenied = false
        var detail: String?

        var phase: CallPhase { machine.phase }
    }

    private(set) var session: Session?
    /// Short-lived message for the popover ("Alex is offline right now.").
    var toast: String?

    /// Fired whenever `session` changes so the app can show / hide call windows.
    var onChange: (() -> Void)?

    private let backend: Backend
    private let hub: RealtimeHub
    private let settings: SettingsStore
    private let notifications: NotificationService
    private let friends: FriendsService
    private let ringtone = Ringtone()
    private let routing = CallAudioRouting()

    private var rtc: WebRTCClient?
    private var signalChannel: RealtimeChannelV2?
    private var inbox = SignalInbox()
    private var signalChain: Task<Void, Never>?
    private var timers: [Task<Void, Never>] = []
    private var pollTask: Task<Void, Never>?
    private var qualityTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var handledCallIDs: Set<UUID> = []
    private var toastTask: Task<Void, Never>?

    init(backend: Backend, hub: RealtimeHub, settings: SettingsStore, notifications: NotificationService, friends: FriendsService) {
        self.backend = backend
        self.hub = hub
        self.settings = settings
        self.notifications = notifications
        self.friends = friends
    }

    private var me: UUID? { backend.currentUserID }
    private var isOfferer: Bool { session?.direction == .outgoing }

    // MARK: - Outgoing

    func call(_ friend: Friend) async {
        if let session, !session.phase.isTerminal {
            if session.peer.id == friend.id { return } // duplicate click
            show(toast: MacTalkError.alreadyInCall.errorDescription)
            return
        }
        guard friend.effectivePresence().isCallable else {
            let error: MacTalkError = switch friend.effectivePresence() {
            case .busy: .friendBusy(friend.name)
            case .dnd: .friendDND(friend.name)
            case .inCall: .friendInCall(friend.name)
            default: .friendOffline(friend.name)
            }
            show(toast: error.errorDescription)
            return
        }
        // Ask for the microphone before ringing anyone (no audio is captured yet).
        guard await MicrophonePermission.ensure() else {
            show(toast: MacTalkError.microphoneDenied.errorDescription)
            session = Session(callID: nil, direction: .outgoing, peer: CallPeer(friend: friend),
                              machine: CallStateMachine(direction: .outgoing), micDenied: true)
            session?.machine.transition(to: .failed)
            session?.detail = MacTalkError.microphoneDenied.errorDescription
            changed()
            return
        }

        session = Session(callID: nil, direction: .outgoing, peer: CallPeer(friend: friend),
                          machine: CallStateMachine(direction: .outgoing))
        changed()

        do {
            let record: CallRecord = try await backend.rpc("start_call", ["p_receiver_id": .uuid(friend.id)], peerName: friend.name)
            guard session?.callID == nil, session?.peer.id == friend.id else {
                // The user cancelled while the request was in flight.
                _ = try? await backend.rpc("cancel_call", ["p_call_id": .uuid(record.id)], as: CallRecord.self)
                return
            }
            handledCallIDs.insert(record.id)
            session?.callID = record.id
            session?.expiresAt = record.expiresAt
            session?.machine.transition(to: .ringing)
            changed()
            startPolling()
            schedule(at: record.expiresAt.addingTimeInterval(1)) { [weak self] in
                guard let self, self.session?.callID == record.id, self.session?.phase == .ringing else { return }
                await self.cancelOutgoing(reason: .missed)
            }
        } catch let error as MacTalkError {
            if case .crossedCall(let incomingID) = error {
                // We both pressed Call at the same time: just pick up their call.
                session = nil
                await adoptCrossedCall(incomingID)
                return
            }
            let phase: CallPhase = switch error {
            case .friendInCall, .friendBusy: .busy
            default: .failed
            }
            finish(phase, detail: error.errorDescription)
        } catch {
            finish(.failed, detail: Backend.map(error).errorDescription)
        }
    }

    private func adoptCrossedCall(_ callID: UUID) async {
        guard let record: CallRecord = try? await backend.client.from("calls").select().eq("id", value: callID).single().execute().value else { return }
        await presentIncoming(record)
        await accept()
    }

    // MARK: - Incoming

    /// Entry point for every call row we learn about (Realtime, heartbeat fallback, polling).
    func handleServer(_ record: CallRecord) {
        guard let me else { return }
        if let session, session.callID == record.id {
            apply(record)
            return
        }
        if record.receiverID == me, record.status == .ringing, !record.isExpired(), !handledCallIDs.contains(record.id) {
            Task { await presentIncoming(record) }
        }
    }

    private func presentIncoming(_ record: CallRecord) async {
        guard !handledCallIDs.contains(record.id) else { return }
        if let session, !session.phase.isTerminal { return } // server already prevents this
        handledCallIDs.insert(record.id)

        var peer = friends.friend(id: record.callerID).map(CallPeer.init(friend:))
        if peer == nil {
            let peers: [CallPeer] = (try? await backend.rpc("get_call_peer", ["p_call_id": .uuid(record.id)])) ?? []
            peer = peers.first
        }
        guard let peer else { return }

        var machine = CallStateMachine(direction: .incoming)
        machine.apply(serverStatus: record.status)
        session = Session(callID: record.id, direction: .incoming, peer: peer, machine: machine, expiresAt: record.expiresAt)
        changed()

        if settings.ringtoneEnabled { ringtone.start(name: settings.ringtoneName, volume: settings.ringtoneVolume) }
        if settings.notificationsEnabled, settings.alertStyle != .callWindow {
            notifications.showIncomingCall(callID: record.id, callerName: peer.name, preview: settings.preview,
                                           avatar: await AvatarImageLoader.image(for: peer.avatarURL))
        }
        startPolling()
        schedule(at: record.expiresAt) { [weak self] in
            guard let self, self.session?.callID == record.id, self.session?.phase == .ringing else { return }
            self.notifications.showMissedCall(from: peer, preview: self.settings.preview)
            self.finish(.missed, detail: "Missed call from \(peer.name)")
        }
    }

    func accept() async {
        guard var s = session, s.direction == .incoming, s.phase == .ringing, let callID = s.callID else { return }
        ringtone.stop()
        notifications.clearIncomingCall(callID)
        NSApp.activate(ignoringOtherApps: true)

        guard await MicrophonePermission.ensure() else {
            s.micDenied = true
            s.detail = MacTalkError.microphoneDenied.errorDescription
            session = s
            changed()
            return
        }
        do {
            let record: CallRecord = try await backend.rpc("answer_call", ["p_call_id": .uuid(callID), "p_accept": .bool(true)])
            apply(record)
        } catch {
            finish(.missed, detail: Backend.map(error).errorDescription)
        }
    }

    func decline() async {
        guard let s = session, s.direction == .incoming, let callID = s.callID, s.phase == .ringing else { return }
        ringtone.stop()
        _ = try? await backend.rpc("answer_call", ["p_call_id": .uuid(callID), "p_accept": .bool(false)], as: CallRecord.self)
        finish(.declined, detail: nil, linger: false)
    }

    // MARK: - Ending

    /// The red button: cancels a ringing outgoing call, declines an incoming one, or hangs up.
    func endCall() async {
        guard let s = session else { return }
        if s.phase.isTerminal { dismiss(); return }
        switch (s.direction, s.phase) {
        case (.incoming, .ringing): await decline()
        case (.outgoing, .initiating), (.outgoing, .ringing): await cancelOutgoing(reason: .cancelled)
        default:
            if let callID = s.callID {
                _ = try? await backend.rpc("end_call", ["p_call_id": .uuid(callID), "p_reason": .string("hangup")], as: CallRecord.self)
            }
            await sendSignal(.bye, .init())
            finish(.ended, detail: nil)
        }
    }

    private func cancelOutgoing(reason: CallPhase) async {
        guard let s = session else { return }
        if let callID = s.callID {
            _ = try? await backend.rpc("cancel_call", ["p_call_id": .uuid(callID)], as: CallRecord.self)
        }
        finish(reason, detail: reason == .missed ? "\(s.peer.name) didn't answer." : nil, linger: reason == .missed)
    }

    func dismiss() {
        guard session?.phase.isTerminal == true || session?.micDenied == true else { return }
        if let s = session, s.micDenied, s.phase == .ringing { Task { await decline() }; return }
        session = nil
        changed()
    }

    // MARK: - Server state

    private func apply(_ record: CallRecord) {
        guard var s = session, s.callID == record.id else { return }
        let before = s.phase
        s.machine.apply(serverStatus: record.status)
        session = s
        guard s.phase != before else { return }

        switch s.phase {
        case .accepted:
            changed()
            Task { await beginMedia() }
        case .declined:
            finish(.declined, detail: "\(s.peer.name) declined the call.")
        case .missed:
            if s.direction == .incoming { notifications.showMissedCall(from: s.peer, preview: settings.preview) }
            finish(.missed, detail: s.direction == .outgoing ? "\(s.peer.name) didn't answer." : "Missed call from \(s.peer.name)")
        case .cancelled:
            if s.direction == .incoming { notifications.showMissedCall(from: s.peer, preview: settings.preview) }
            finish(.cancelled, detail: "\(s.peer.name) cancelled the call.", linger: s.direction == .outgoing)
        case .ended:
            finish(.ended, detail: before == .connected || before == .reconnecting ? "\(s.peer.name) ended the call." : nil)
        case .failed:
            finish(.failed, detail: MacTalkError.webRTCFailed.errorDescription)
        case .busy:
            finish(.busy, detail: MacTalkError.friendInCall(s.peer.name).errorDescription)
        default:
            changed()
        }
    }

    // MARK: - Media

    private func beginMedia() async {
        guard let s = session, s.phase == .accepted, let callID = s.callID, rtc == nil else { return }
        ringtone.stop()
        session?.machine.transition(to: .connecting)
        changed()
        _ = try? await backend.rpc("update_call_state", ["p_call_id": .uuid(callID), "p_status": .string("connecting")], as: CallRecord.self)

        routing.apply(inputUID: settings.inputDeviceUID, outputUID: settings.outputDeviceUID)
        let iceServers = await fetchIceServers()
        guard session?.callID == callID, session?.phase.isTerminal == false else { return }

        let client = WebRTCClient(iceServers: iceServers) { [weak self] event in
            Task { @MainActor in self?.handle(event, callID: callID) }
        }
        guard let client else { await fail(); return }
        client.setOutputVolume(settings.outputVolume)
        rtc = client
        inbox = SignalInbox()

        signalChannel = await hub.signals(callID: callID) { [weak self] row in self?.enqueue(row) }
        await catchUpSignals()

        if isOfferer {
            do {
                let sdp = try await client.makeOffer()
                await sendSignal(.offer, .description(sdp))
            } catch { await fail() }
        }

        // Give up if audio hasn't connected in 30 s.
        schedule(after: .seconds(30)) { [weak self] in
            guard let self, self.session?.callID == callID,
                  [.accepted, .connecting].contains(self.session?.phase) else { return }
            await self.fail()
        }
    }

    private func fetchIceServers() async -> [IceServerConfig] {
        struct Response: Decodable { let iceServers: [IceServerConfig] }
        do {
            let response: Response = try await backend.client.functions.invoke("turn-credentials", options: .init(method: .post))
            return response.iceServers.isEmpty ? IceServerConfig.publicSTUN : response.iceServers
        } catch {
            return IceServerConfig.publicSTUN
        }
    }

    private func handle(_ event: WebRTCClient.Event, callID: UUID) {
        guard session?.callID == callID else { return }
        switch event {
        case .localCandidate(let payload):
            Task { await sendSignal(.ice, payload) }
        case .connection(let state):
            switch state {
            case .connected, .completed:
                restartTask?.cancel()
                if session?.machine.transition(to: .connected) == true {
                    if session?.connectedAt == nil {
                        session?.connectedAt = Date()
                        Task { _ = try? await backend.rpc("update_call_state", ["p_call_id": .uuid(callID), "p_status": .string("connected")], as: CallRecord.self) }
                    }
                    session?.detail = nil
                    startQualitySampling()
                    changed()
                }
            case .disconnected:
                if session?.machine.transition(to: .reconnecting) == true { changed() }
                scheduleIceRestart(after: .seconds(2))
            case .failed:
                if session?.phase == .connected || session?.phase == .reconnecting {
                    session?.machine.transition(to: .reconnecting)
                    changed()
                    scheduleIceRestart(after: .zero)
                } else {
                    Task { await fail() }
                }
            default:
                break
            }
        }
    }

    /// Called by the app when the network path changes during a call.
    func networkChanged(isOnline: Bool) {
        guard let phase = session?.phase, [.connected, .reconnecting].contains(phase) else { return }
        if !isOnline {
            if session?.machine.transition(to: .reconnecting) == true {
                session?.detail = MacTalkError.network.errorDescription
                changed()
            }
        } else {
            scheduleIceRestart(after: .milliseconds(500))
        }
    }

    private func scheduleIceRestart(after delay: Duration) {
        guard let callID = session?.callID else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.session?.phase == .reconnecting else { return }
            if self.isOfferer {
                if let sdp = try? await self.rtc?.makeOffer(iceRestart: true) { await self.sendSignal(.offer, .description(sdp)) }
            } else {
                await self.sendSignal(.restart, .init())
            }
            // Still not back after 20 s: end the call.
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, self.session?.callID == callID, self.session?.phase == .reconnecting else { return }
            await self.fail()
        }
        startPolling()
    }

    private func fail() async {
        guard let callID = session?.callID, session?.phase.isTerminal == false else { return }
        _ = try? await backend.rpc("end_call", ["p_call_id": .uuid(callID), "p_reason": .string("failed")], as: CallRecord.self)
        finish(.failed, detail: MacTalkError.webRTCFailed.errorDescription)
    }

    // MARK: - Signaling

    private func sendSignal(_ kind: SignalKind, _ payload: SignalPayload) async {
        guard let s = session, let callID = s.callID, let me else { return }
        let row = SignalRow(callID: callID, senderID: me, recipientID: s.peer.id, kind: kind, payload: payload)
        _ = try? await backend.client.from("call_signals").insert(row).execute()
    }

    /// Fetches any signals Realtime didn't deliver (subscribe race, brief disconnect).
    private func catchUpSignals() async {
        guard let callID = session?.callID, let me else { return }
        let rows: [SignalRow] = (try? await backend.client.from("call_signals").select()
            .eq("call_id", value: callID).eq("recipient_id", value: me)
            .gt("id", value: inbox.lastProcessedID).order("id").execute().value) ?? []
        rows.forEach(enqueue)
    }

    /// Processes signals strictly in order.
    private func enqueue(_ row: SignalRow) {
        guard row.callID == session?.callID, inbox.accept(row) else { return }
        let previous = signalChain
        signalChain = Task { [weak self] in
            await previous?.value
            await self?.process(row)
        }
    }

    private func process(_ row: SignalRow) async {
        guard let rtc else { return }
        do {
            switch row.kind {
            case .offer:
                guard let sdp = row.payload.sdp else { return }
                try await rtc.setRemote(sdp: sdp, isOffer: true)
                for candidate in inbox.drainCandidates() { await rtc.add(candidate: candidate) }
                let answer = try await rtc.makeAnswer()
                await sendSignal(.answer, .description(answer))
            case .answer:
                guard isOfferer, let sdp = row.payload.sdp else { return }
                try await rtc.setRemote(sdp: sdp, isOffer: false)
                for candidate in inbox.drainCandidates() { await rtc.add(candidate: candidate) }
            case .ice:
                if rtc.hasRemoteDescription { await rtc.add(candidate: row.payload) } else { inbox.buffer(row.payload) }
            case .restart:
                if isOfferer, let sdp = try? await rtc.makeOffer(iceRestart: true) { await sendSignal(.offer, .description(sdp)) }
            case .bye:
                if session?.phase.isTerminal == false {
                    finish(.ended, detail: "\(session?.peer.name ?? "They") ended the call.")
                }
            }
        } catch {
            await fail()
        }
    }

    // MARK: - Fallback polling

    /// While a call is ringing or connecting, re-read the call row and signals every 3 s in
    /// case a Realtime event was missed. Stops once the call is connected or over.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, let s = self.session, let callID = s.callID, !s.phase.isTerminal else { break }
                if s.phase == .connected { continue }
                if let record: CallRecord = try? await self.backend.client.from("calls").select()
                    .eq("id", value: callID).single().execute().value {
                    self.apply(record)
                }
                if self.rtc != nil { await self.catchUpSignals() }
            }
            self?.pollTask = nil
        }
    }

    private func startQualitySampling() {
        guard qualityTask == nil else { return }
        qualityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let rtc = self.rtc else { break }
                let q = await rtc.quality()
                if self.session?.quality != q { self.session?.quality = q; self.changed() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Controls

    func toggleMute() {
        guard let rtc, var s = session else { return }
        s.isMuted.toggle()
        rtc.isMuted = s.isMuted
        session = s
        changed()
    }

    func setOutputVolume(_ value: Double) {
        settings.outputVolume = value
        rtc?.setOutputVolume(value)
    }

    func switchInput(to uid: String) { routing.switchInput(to: uid) }
    func switchOutput(to uid: String) { routing.switchOutput(to: uid) }

    /// Called on quit: end any call cleanly so the friend isn't left hanging.
    func endForTermination() async {
        guard let s = session, !s.phase.isTerminal, let callID = s.callID else { return }
        if s.direction == .outgoing, s.phase == .ringing {
            _ = try? await backend.rpc("cancel_call", ["p_call_id": .uuid(callID)], as: CallRecord.self)
        } else if s.direction == .incoming, s.phase == .ringing {
            _ = try? await backend.rpc("answer_call", ["p_call_id": .uuid(callID), "p_accept": .bool(false)], as: CallRecord.self)
        } else {
            _ = try? await backend.rpc("end_call", ["p_call_id": .uuid(callID), "p_reason": .string("app_quit")], as: CallRecord.self)
        }
        teardownMedia()
    }

    // MARK: - Teardown

    private func finish(_ phase: CallPhase, detail: String?, linger: Bool = true) {
        ringtone.stop()
        if let callID = session?.callID { notifications.clearIncomingCall(callID) }
        teardownMedia()
        guard var s = session else { return }
        if !s.machine.transition(to: phase), !s.phase.isTerminal {
            s.machine = CallStateMachine.forcedTerminal(direction: s.direction, phase: phase)
        }
        s.detail = detail
        session = s
        changed()
        let finished = s.callID
        if linger {
            schedule(after: .seconds(2.5)) { [weak self] in
                guard let self, self.session?.callID == finished, self.session?.phase.isTerminal == true else { return }
                self.session = nil
                self.changed()
            }
        } else {
            session = nil
            changed()
        }
    }

    private func teardownMedia() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
        pollTask?.cancel(); pollTask = nil
        qualityTask?.cancel(); qualityTask = nil
        restartTask?.cancel(); restartTask = nil
        signalChain?.cancel(); signalChain = nil
        rtc?.close()
        rtc = nil
        if let channel = signalChannel {
            signalChannel = nil
            Task { await hub.remove(channel) }
        }
        routing.restore()
    }

    // MARK: - Helpers

    #if DEBUG
    func debugSet(_ session: Session?) { self.session = session }
    #endif

    private func changed() { onChange?() }

    func show(toast message: String?) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func schedule(after delay: Duration, _ work: @escaping @MainActor () async -> Void) {
        timers.append(Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await work()
        })
    }

    private func schedule(at date: Date, _ work: @escaping @MainActor () async -> Void) {
        schedule(after: .milliseconds(max(0, Int(date.timeIntervalSinceNow * 1000))), work)
    }
}

extension CallStateMachine {
    /// Used only when the server reports an end state the local machine can't reach
    /// through a normal transition (e.g. a call blocked mid-setup).
    static func forcedTerminal(direction: CallDirection, phase: CallPhase) -> CallStateMachine {
        var machine = CallStateMachine(direction: direction)
        if direction == .outgoing { machine.transition(to: .ringing) }
        if !machine.transition(to: phase) { machine.transition(to: .failed) }
        return machine
    }
}
