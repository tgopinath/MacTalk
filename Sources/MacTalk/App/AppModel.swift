import AppKit
import MacTalkCore
import Observation
import SwiftUI

/// Composition root: creates every service once and wires their events together.
@MainActor @Observable
final class AppModel {
    let configuration: AppConfiguration
    let settings = SettingsStore()
    let network = NetworkMonitor()
    let notifications = NotificationService()
    let windows = WindowManager()

    let backend: Backend?
    let auth: AuthService?
    let friends: FriendsService?
    let calls: CallManager?
    private let hub: RealtimeHub?
    private let presence: PresenceService?
    private let hotkeys = SpeedDialHotkeys()

    private(set) var speedDial = SpeedDial()
    private(set) var ringFrame = 0
    private(set) var hotkeyConflicts: [Int] = []
    private var ringAnimation: Task<Void, Never>?
    private var started = false
    private var knownIncomingRequestIDs: Set<String>?

    init(bundle: Bundle = .main, configuration override: AppConfiguration? = nil) {
        configuration = override ?? AppConfiguration(infoDictionary: bundle.infoDictionary ?? [:])
        backend = Backend(configuration: configuration)
        if let backend {
            let hub = RealtimeHub(backend: backend)
            let friends = FriendsService(backend: backend)
            self.hub = hub
            self.friends = friends
            auth = AuthService(backend: backend)
            presence = PresenceService(backend: backend, hub: hub)
            calls = CallManager(backend: backend, settings: settings, notifications: notifications, friends: friends)
        } else {
            hub = nil; friends = nil; auth = nil; presence = nil; calls = nil
        }
        wire()
    }

    // MARK: Wiring

    private func wire() {
        notifications.configure()
        settings.applyAppearance()

        notifications.onAction = { [weak self] action in self?.handle(action) }
        network.onChange = { [weak self] online in
            guard let self else { return }
            self.calls?.networkChanged(isOnline: online)
            if online { self.presence?.recover() }
        }

        guard let auth, let hub, let presence, let calls, let friends else { return }

        auth.onStateChange = { [weak self] state in self?.authChanged(state) }

        hub.onUserNode = { [weak friends] node in friends?.apply(userNode: node) }
        hub.onInbox = { [weak self] node in
            self?.friends?.apply(inboxNode: node)
            self?.announceNewRequests()
        }
        hub.onRings = { [weak calls] rings in calls?.handleRings(rings) }
        presence.onRings = { [weak calls] rings in calls?.handleRings(rings) }
        presence.onUserNode = { [weak friends] node in friends?.apply(userNode: node) }
        presence.onBeat = { [weak friends] in await friends?.refreshPresence() }
        presence.activeCallID = { [weak calls] in calls?.activeCallID }
        calls.myIdentity = { [weak auth] in (auth?.profile?.name ?? "", auth?.profile?.avatarURL) }

        calls.onChange = { [weak self] in self?.callChanged() }

        hotkeys.onSlot = { [weak self] slot in self?.speedDial(slot: slot) }
    }

    /// Called once the menu bar item exists.
    func launch() {
        guard !started else { return }
        started = true
        if backend == nil { return }
        if settings.openAtStartup { MenuBarPopover.open() }
    }

    private func authChanged(_ state: AuthService.State) {
        switch state {
        case .signedIn(let profile):
            windows.close(.onboarding)
            Task { await startSession(for: profile) }
        case .signedOut, .needsProfile:
            if case .signedOut = state { Task { await stopSession() } }
            windows.showOnboarding(model: self)
        case .loading:
            break
        }
    }

    private var sessionUser: UserID?

    private func startSession(for profile: UserProfile) async {
        guard sessionUser != profile.id, let hub, let presence, let friends else { return }
        sessionUser = profile.id
        speedDial = settings.speedDial(for: profile.id)
        friends.setLoading()
        if !settings.autoGoOnline, profile.manualStatus == .online {
            try? await presence.setStatus(.dnd)
            auth?.setLocalStatus(.dnd)
        }
        hub.start(userID: profile.id)
        presence.start()
        applyHotkeys()
        if notifications.authorization == .notDetermined { await notifications.requestAuthorization() }
    }

    private func stopSession() async {
        guard sessionUser != nil else { return }
        sessionUser = nil
        presence?.stop()
        hub?.stop()
        friends?.reset()
        hotkeys.unregister()
    }

    // MARK: Calls

    private func callChanged() {
        guard let calls else { return }
        let session = calls.session
        let ringing = session?.direction == .incoming && (session?.phase == .ringing || (session?.micDenied ?? false) && session?.phase == .ringing)
        let useWindow = settings.alertStyle != .systemNotification || !settings.notificationsEnabled
            || notifications.authorization != .authorized

        if ringing, useWindow {
            windows.showIncomingCall(model: self)
        } else {
            windows.close(.incomingCall)
        }

        if let session, !(session.direction == .incoming && session.phase == .ringing) {
            windows.showActiveCall(model: self)
        } else if session == nil {
            windows.close(.activeCall)
        }

        if ringing { startRingAnimation() } else { ringAnimation?.cancel(); ringAnimation = nil }
    }

    private func startRingAnimation() {
        guard ringAnimation == nil else { return }
        ringAnimation = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                self?.ringFrame += 1
            }
        }
    }

    var menuBarState: MenuBarState {
        if let s = calls?.session, !s.phase.isTerminal {
            if s.direction == .incoming, s.phase == .ringing { return .ringing(frame: ringFrame) }
            return .inCall
        }
        guard case .signedIn(let profile) = auth?.state, network.isOnline else { return .offline }
        return profile.manualStatus == .online ? .online : .busy
    }

    // MARK: Friends & speed dial

    var orderedFriends: [Friend] { speedDial.ordered(friends?.friends ?? []) }

    func slot(for friend: Friend) -> Int? {
        settings.speedDialEnabled ? speedDial.slot(for: friend.id, in: friends?.friends ?? []) : nil
    }

    func moveFriends(from source: IndexSet, to destination: Int) {
        guard let uid = auth?.userID else { return }
        speedDial.move(in: friends?.friends ?? [], from: source, to: destination)
        settings.save(speedDial, for: uid)
    }

    func applyHotkeys() {
        if settings.speedDialEnabled, sessionUser != nil {
            hotkeys.register(modifier: settings.speedDialModifier)
            hotkeyConflicts = hotkeys.failedSlots
        } else {
            hotkeys.unregister()
            hotkeyConflicts = []
        }
    }

    /// ⌃N: call friend N. Pressing it again while talking to / ringing that friend hangs up;
    /// pressing it while that friend is calling you answers.
    private func speedDial(slot: Int) {
        guard let calls, let friends, let friend = speedDial.friend(forSlot: slot, in: friends.friends) else {
            NSSound.beep()
            return
        }
        if let s = calls.session, !s.phase.isTerminal, s.peer.id == friend.id {
            Task { s.direction == .incoming && s.phase == .ringing ? await calls.accept() : await calls.endCall() }
            return
        }
        Task { await calls.call(friend) }
        if calls.toast != nil { MenuBarPopover.open() }
    }

    func setStatus(_ status: ManualStatus) {
        auth?.setLocalStatus(status)
        Task {
            do { try await presence?.setStatus(status) } catch { calls?.show(toast: Backend.map(error).errorDescription) }
        }
    }

    private func announceNewRequests() {
        guard let friends else { return }
        // The first snapshot after launch is not "new".
        if let known = knownIncomingRequestIDs {
            for request in friends.incomingRequests where !known.contains(request.id) {
                if settings.notificationsEnabled { notifications.showFriendRequest(request) }
            }
        }
        knownIncomingRequestIDs = Set(friends.incomingRequests.map(\.id))
    }

    // MARK: Notification actions

    private func handle(_ action: NotificationService.Action) {
        guard let calls, let friends else { return }
        switch action {
        case .accept(let id) where calls.session?.callID == id: Task { await calls.accept() }
        case .decline(let id) where calls.session?.callID == id: Task { await calls.decline() }
        case .callBack(let peerID):
            if let friend = friends.friend(id: peerID) { Task { await calls.call(friend) } }
        case .acceptFriend(let requestID):
            if let request = friends.requests.first(where: { $0.id == requestID }) {
                Task { try? await friends.respond(request, accept: true) }
            }
        default:
            MenuBarPopover.open()
        }
    }

    // MARK: Lifecycle

    func prepareForTermination() async {
        await calls?.endForTermination()
        await presence?.goOffline()
    }

    func signOut() async {
        await calls?.endForTermination()
        await auth?.signOut()
    }
}
