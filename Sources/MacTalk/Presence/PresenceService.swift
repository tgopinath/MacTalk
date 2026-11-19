import AppKit
import Foundation
import MacTalkCore

/// Keeps the user's presence fresh with a 25 s heartbeat, goes offline on sleep / quit,
/// and recovers the live streams after wake or network changes.
///
/// Each heartbeat also re-reads friends' presence and any pending call rings, which is
/// the fallback if a live-stream event was lost.
@MainActor
final class PresenceService {
    var onRings: (([CallID: RingEntry]) -> Void)?
    /// Fallback copy of `u/{uid}` (friends, invitations sent, blocks) in case the live stream missed an update.
    var onUserNode: (([String: Any]?) -> Void)?
    var onBeat: (() async -> Void)?
    /// The call this user is in, refreshed on every beat so friends see "In a call".
    var activeCallID: (() -> CallID?)?

    private let backend: Backend
    private let hub: RealtimeHub
    private var loop: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    init(backend: Backend, hub: RealtimeHub) {
        self.backend = backend
        self.hub = hub
        let ws = NSWorkspace.shared.notificationCenter
        observers = [
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSleep() }
            },
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWake() }
            },
        ]
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.beat()
                try? await Task.sleep(for: .seconds(PresenceResolver.heartbeatInterval))
            }
        }
    }

    func stop() {
        isRunning = false
        loop?.cancel()
        loop = nil
    }

    func beatNow() { Task { await beat() } }

    private func beat() async {
        guard let uid = backend.currentUserID else { return }
        var values: [String: Any] = ["users/\(uid)/online": true, "users/\(uid)/lastSeen": RealtimeDatabase.serverTimestamp]
        if let callID = activeCallID?() {
            values["users/\(uid)/inCall"] = ["callId": callID, "at": RealtimeDatabase.serverTimestamp]
        } else {
            values["users/\(uid)/inCall"] = NSNull()
        }
        do {
            try await backend.db.update(values)
            let node = try await backend.db.getJSON("u/\(uid)") as? [String: Any]
            onUserNode?(node)
            onRings?(RealtimeHub.rings(from: node?["rings"]))
        } catch {
            // Expected while offline; NetworkMonitor triggers recovery.
        }
        await onBeat?()
    }

    func setStatus(_ status: ManualStatus) async throws {
        guard let uid = backend.currentUserID else { return }
        do {
            try await backend.db.update(["users/\(uid)/status": status.rawValue, "users/\(uid)/online": true,
                                         "users/\(uid)/lastSeen": RealtimeDatabase.serverTimestamp])
        } catch { throw Backend.map(error) }
    }

    /// Best effort, bounded so sleep / quit is never delayed by a slow network.
    func goOffline(timeout: Duration = .seconds(2)) async {
        guard let uid = backend.currentUserID else { return }
        let write = Task { @MainActor [backend] in
            try? await backend.db.update(["users/\(uid)/online": false, "users/\(uid)/inCall": NSNull()])
        }
        let deadline = Task { try? await Task.sleep(for: timeout); write.cancel() }
        await write.value
        deadline.cancel()
    }

    private func handleSleep() {
        guard isRunning else { return }
        loop?.cancel()
        Task { await goOffline(timeout: .seconds(1)) }
    }

    private func handleWake() {
        guard isRunning else { return }
        isRunning = false
        recover()
    }

    /// Reconnect after wake or when the network comes back.
    func recover() {
        guard backend.currentUserID != nil, hub.userID != nil else { return }
        hub.restart()
        stop()
        start()
    }
}
