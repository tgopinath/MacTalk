import AppKit
import Foundation
import MacTalkCore
import Observation
@preconcurrency import WebRTC

/// Drives one call at a time from "Call" (or an incoming ring) to hang-up.
///
/// Flow (Realtime Database, every write checked by database.rules.json)
/// 1. Caller writes `calls/{id}` (status `ringing`) and `u/{callee}/rings/{id}` in one atomic
///    update. The rules only allow it between mutual friends, neither blocked, callee online,
///    not DND/busy, not already in a call, and at most one call every 3 s.
/// 2. Callee's `u/{uid}` stream sees the ring → ringtone + bottom-right alert. The microphone
///    is not opened while ringing.
/// 3. Callee accepts → status `accepted` → both sides open WebRTC. The caller sends the SDP
///    offer; answer and ICE candidates flow through `calls/{id}/signals` (writable only by the
///    two participants, only after acceptance).
/// 4. Either side ends → status `ended`; the caller deletes the call record shortly after.
@MainActor @Observable
final class CallManager {
    struct Session {
        var callID: CallID?
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
    /// Current user's display name / photo, used on the callee's ring.
    var myIdentity: (() -> (name: String, photo: String?))?

    private let backend: Backend
    private let settings: SettingsStore
    private let notifications: NotificationService
    private let friends: FriendsService
    private let ringtone = Ringtone()
    private let routing = CallAudioRouting()

    private var rtc: WebRTCClient?
    private var callStream: Task<Void, Never>?
    private var inbox = SignalInbox()
    private var signalChain: Task<Void, Never>?
    private var timers: [Task<Void, Never>] = []
    private var pollTask: Task<Void, Never>?
    private var qualityTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var handledCallIDs: Set<CallID> = []
    private var toastTask: Task<Void, Never>?

    init(backend: Backend, settings: SettingsStore, notifications: NotificationService, friends: FriendsService) {
        self.backend = backend
        self.settings = settings
        self.notifications = notifications
        self.friends = friends
    }

    private var me: UserID? { backend.currentUserID }
    private var db: RealtimeDatabase { backend.db }
    private var isOfferer: Bool { session?.direction == .outgoing }

    /// The call this user is part of right now (for the presence heartbeat).
    var activeCallID: CallID? {
        guard let s = session, !s.phase.isTerminal else { return nil }
        return s.callID
    }

    // MARK: - Outgoing

    func call(_ friend: Friend) async {
        if let s = session, !s.phase.isTerminal {
            if s.peer.id == friend.id {
                // They're ringing us right now: pick up instead of calling back.
                if s.direction == .incoming && s.phase == .ringing { await accept() }
                return
            }
            show(toast: MacTalkError.alreadyInCall.errorDescription)
            return
        }
        guard let me else { return }

        // Fresh presence check so the message is specific (the database rules enforce it anyway).
        let record = (try? await db.get("users/\(friend.id)", as: UserRecord.self)) ?? nil
        let presence = record?.presence() ?? friend.effectivePresence()
        guard presence.isCallable else {
            let error: MacTalkError = switch presence {
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
            var s = Session(callID: nil, direction: .outgoing, peer: CallPeer(friend: friend),
                            machine: .forcedTerminal(direction: .outgoing, phase: .failed), micDenied: true)
            s.detail = MacTalkError.microphoneDenied.errorDescription
            session = s
            changed()
            return
        }

        let callID = Self.newCallID()
        let expiresAt = Date().addingTimeInterval(45)
        session = Session(callID: callID, direction: .outgoing, peer: CallPeer(friend: friend),
                          machine: CallStateMachine(direction: .outgoing), expiresAt: expiresAt)
        handledCallIDs.insert(callID)
        changed()

        let identity = myIdentity?() ?? (name: "", photo: nil)
        let ts = RealtimeDatabase.serverTimestamp
        let expiresMs = Int(expiresAt.timeIntervalSince1970 * 1000)
        do {
            try await db.update([
                "calls/\(callID)": ["caller": me, "callee": friend.id, "callerName": identity.name,
                                    "callerPhoto": identity.photo ?? NSNull(), "status": "ringing",
                                    "createdAt": ts, "expiresAt": expiresMs],
                "u/\(friend.id)/rings/\(callID)": ["caller": me, "callerName": identity.name,
                                                   "callerPhoto": identity.photo ?? NSNull(), "expiresAt": expiresMs],
                "users/\(me)/lastCallAt": ts,
                "users/\(me)/inCall": ["callId": callID, "at": ts],
            ])
        } catch {
            let mapped = Backend.map(error)
            finish(.failed, detail: mapped == .permissionDenied
                   ? "Couldn't ring \(friend.name). They may have just gone offline or busy."
                   : mapped.errorDescription)
            return
        }
        guard session?.callID == callID, session?.phase == .initiating else { return } // cancelled meanwhile
        session?.machine.transition(to: .ringing)
        changed()
        observeCall(callID)
        startPolling()
        schedule(at: expiresAt.addingTimeInterval(1)) { [weak self] in
            guard let self, self.session?.callID == callID, self.session?.phase == .ringing else { return }
            await self.cancelOutgoing(reason: .missed)
        }
    }

    /// Chronological, collision-resistant id (like a Firebase push key).
    static func newCallID() -> CallID {
        let ms = String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "c" + ms + String((0..<10).map { _ in alphabet.randomElement()! })
    }

    // MARK: - Incoming

    /// Rings from the live `u/{uid}` stream or the heartbeat fallback.
    func handleRings(_ rings: [CallID: RingEntry]) {
        let now = Date()
        for (id, ring) in rings.sorted(by: { $0.key < $1.key }) where !handledCallIDs.contains(id) {
            if ring.expiresAt < now {
                handledCallIDs.insert(id)
                if let me { Task { try? await db.delete("u/\(me)/rings/\(id)") } }
                continue
            }
            Task { await presentIncoming(id: id, ring: ring) }
        }
    }

    private func presentIncoming(id: CallID, ring: RingEntry) async {
        guard !handledCallIDs.contains(id), let me else { return }
        handledCallIDs.insert(id)
        if let s = session, !s.phase.isTerminal {
            // Already talking to someone: tell this caller we're busy.
            try? await db.update(["calls/\(id)/status": "busy", "calls/\(id)/endedAt": RealtimeDatabase.serverTimestamp,
                                  "u/\(me)/rings/\(id)": NSNull()])
            return
        }
        guard let record = try? await db.get("calls/\(id)", as: CallRecord.self), record.status == .ringing,
              record.callee == me else {
            try? await db.delete("u/\(me)/rings/\(id)")
            return
        }
        let friend = friends.friend(id: ring.caller)
        let peer = friend.map(CallPeer.init(friend:))
            ?? CallPeer(id: ring.caller, displayName: ring.callerName, avatarURL: ring.callerPhoto, email: nil)

        session = Session(callID: id, direction: .incoming, peer: peer, machine: CallStateMachine(direction: .incoming),
                          expiresAt: ring.expiresAt)
        changed()
        observeCall(id)

        if settings.ringtoneEnabled { ringtone.start(name: settings.ringtoneName, volume: settings.ringtoneVolume) }
        if settings.notificationsEnabled, settings.alertStyle != .callWindow {
            notifications.showIncomingCall(callID: id, callerName: peer.name, preview: settings.preview,
                                           avatar: await AvatarImageLoader.image(for: peer.avatarURL))
        }
        startPolling()
        schedule(at: ring.expiresAt) { [weak self] in
            guard let self, self.session?.callID == id, self.session?.phase == .ringing else { return }
            self.notifications.showMissedCall(from: peer, preview: self.settings.preview)
            self.finish(.missed, detail: "Missed call from \(peer.name)")
        }
    }

    func accept() async {
        guard var s = session, s.direction == .incoming, s.phase == .ringing, let callID = s.callID, let me else { return }
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
        let ts = RealtimeDatabase.serverTimestamp
        do {
            try await db.update(["calls/\(callID)/status": "accepted", "calls/\(callID)/acceptedAt": ts,
                                 "users/\(me)/inCall": ["callId": callID, "at": ts], "u/\(me)/rings/\(callID)": NSNull()])
            applyStatus(.accepted)
        } catch {
            finish(.missed, detail: MacTalkError.callExpired.errorDescription)
        }
    }

    func decline() async {
        guard let s = session, s.direction == .incoming, let callID = s.callID, s.phase == .ringing, let me else { return }
        ringtone.stop()
        try? await db.update(["calls/\(callID)/status": "declined", "calls/\(callID)/endedAt": RealtimeDatabase.serverTimestamp,
                              "u/\(me)/rings/\(callID)": NSNull()])
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
            await writeEnd(status: "ended")
            finish(.ended, detail: nil)
        }
    }

    private func writeEnd(status: String) async {
        guard let callID = session?.callID else { return }
        try? await db.update(["calls/\(callID)/status": status, "calls/\(callID)/endedAt": RealtimeDatabase.serverTimestamp])
    }

    private func cancelOutgoing(reason: CallPhase) async {
        guard let s = session else { return }
        if let callID = s.callID {
            try? await db.update(["calls/\(callID)/status": reason == .missed ? "missed" : "cancelled",
                                  "calls/\(callID)/endedAt": RealtimeDatabase.serverTimestamp,
                                  "u/\(s.peer.id)/rings/\(callID)": NSNull()])
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

    private func observeCall(_ callID: CallID) {
        callStream?.cancel()
        let stream = db.observe("calls/\(callID)")
        callStream = Task { [weak self] in
            for await tree in stream {
                guard let self, self.session?.callID == callID else { return }
                self.handleCallTree(tree.value, callID: callID)
            }
        }
    }

    private func handleCallTree(_ tree: Any?, callID: CallID) {
        guard let node = tree as? [String: Any] else {
            // The call record was deleted by the other side.
            if session?.phase.isTerminal == false { finish(.ended, detail: nil) }
            return
        }
        if let status = (node["status"] as? String).flatMap(CallRecordStatus.init(rawValue:)) { applyStatus(status) }
        if rtc != nil, let signals = node["signals"] as? [String: Any] { ingest(signals) }
    }

    private func applyStatus(_ status: CallRecordStatus) {
        guard var s = session else { return }
        let before = s.phase
        s.machine.apply(serverStatus: status)
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
        try? await db.update(["calls/\(callID)/status": "connecting"])

        routing.apply(inputUID: settings.inputDeviceUID, outputUID: settings.outputDeviceUID)
        let client = WebRTCClient(iceServers: iceServers) { [weak self] event in
            Task { @MainActor in self?.handle(event, callID: callID) }
        }
        guard let client else { await fail(); return }
        client.setOutputVolume(settings.outputVolume)
        rtc = client
        inbox = SignalInbox()
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

    private var iceServers: [IceServerConfig] {
        var servers = IceServerConfig.publicSTUN
        let c = backend.configuration
        if !c.turnURLs.isEmpty {
            servers.append(IceServerConfig(urls: c.turnURLs, username: c.turnUsername, credential: c.turnCredential))
        }
        return servers
    }

    private func handle(_ event: WebRTCClient.Event, callID: CallID) {
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
                        Task {
                            try? await db.update(["calls/\(callID)/status": "connected",
                                                  "calls/\(callID)/connectedAt": RealtimeDatabase.serverTimestamp])
                        }
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
            if let callID = session?.callID { observeCall(callID) }
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
        guard session?.callID != nil, session?.phase.isTerminal == false else { return }
        await writeEnd(status: "failed")
        finish(.failed, detail: MacTalkError.webRTCFailed.errorDescription)
    }

    // MARK: - Signaling

    private func sendSignal(_ kind: SignalKind, _ payload: SignalPayload) async {
        guard let callID = session?.callID, let me,
              let body = try? JSONSerialization.jsonObject(with: JSONEncoder.firebase.encode(SignalRow(from: me, kind: kind, payload: payload)))
        else { return }
        _ = try? await db.push("calls/\(callID)/signals", body)
    }

    /// Fetches signals the live stream may not have delivered yet.
    private func catchUpSignals() async {
        guard let callID = session?.callID,
              let signals = try? await db.getJSON("calls/\(callID)/signals") as? [String: Any] else { return }
        ingest(signals)
    }

    private func ingest(_ signals: [String: Any]) {
        guard let me else { return }
        for key in signals.keys.sorted() {
            guard var row: SignalRow = JSONTree.decode(signals[key]), row.from != me else { continue }
            row.key = key
            enqueue(row)
        }
    }

    /// Processes signals strictly in order.
    private func enqueue(_ row: SignalRow) {
        guard inbox.accept(row) else { return }
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

    /// While a call is ringing or connecting, re-read the call every 3 s in case the live
    /// stream missed an update. Stops once the call is connected or over.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, let s = self.session, let callID = s.callID, !s.phase.isTerminal else { break }
                if s.phase == .connected { continue }
                if let tree = try? await self.db.getJSON("calls/\(callID)") {
                    self.handleCallTree(tree, callID: callID)
                }
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

    /// Called on quit / sign-out: end any call cleanly so the friend isn't left hanging.
    func endForTermination() async {
        guard let s = session, !s.phase.isTerminal, let callID = s.callID else { return }
        switch (s.direction, s.phase) {
        case (.outgoing, .ringing), (.outgoing, .initiating):
            try? await db.update(["calls/\(callID)/status": "cancelled", "u/\(s.peer.id)/rings/\(callID)": NSNull()])
        case (.incoming, .ringing):
            try? await db.update(["calls/\(callID)/status": "declined", "u/\(me ?? "")/rings/\(callID)": NSNull()])
        default:
            await writeEnd(status: "ended")
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
            s.machine = .forcedTerminal(direction: s.direction, phase: phase)
        }
        s.detail = detail
        session = s
        changed()
        cleanUp(s)
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

    /// Clears this user's busy marker; the caller removes the call record once the other
    /// side has had time to see the final status.
    private func cleanUp(_ s: Session) {
        guard let me, let callID = s.callID else { return }
        let db = self.db
        Task {
            var values: [String: Any] = ["users/\(me)/inCall": NSNull()]
            if s.direction == .incoming { values["u/\(me)/rings/\(callID)"] = NSNull() }
            try? await db.update(values)
            guard s.direction == .outgoing else { return }
            try? await Task.sleep(for: .seconds(15))
            try? await db.update(["calls/\(callID)": NSNull(), "u/\(s.peer.id)/rings/\(callID)": NSNull()])
        }
    }

    private func teardownMedia() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
        pollTask?.cancel(); pollTask = nil
        qualityTask?.cancel(); qualityTask = nil
        restartTask?.cancel(); restartTask = nil
        signalChain?.cancel(); signalChain = nil
        callStream?.cancel(); callStream = nil
        rtc?.close()
        rtc = nil
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
    /// through a normal transition.
    static func forcedTerminal(direction: CallDirection, phase: CallPhase) -> CallStateMachine {
        var machine = CallStateMachine(direction: direction)
        if direction == .outgoing { machine.transition(to: .ringing) }
        if !machine.transition(to: phase) { machine.transition(to: .failed) }
        return machine
    }
}
