import AppKit
import Foundation
import MacTalkCore
import Supabase

/// Keeps the user's presence fresh with a 25 s heartbeat, goes offline on sleep / quit,
/// and recovers the Realtime connection after wake or network changes.
///
/// The heartbeat also returns any call that is ringing for this user, which is the
/// polling fallback in case a Realtime event was lost.
@MainActor
final class PresenceService {
    var onRingingCall: ((CallRecord) -> Void)?
    var onRecovered: (() -> Void)?

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
        do {
            let response = try await backend.client.rpc("heartbeat").execute()
            if let record = try? Backend.decoder.decode(CallRecord.self, from: response.data) {
                onRingingCall?(record)
            }
        } catch {
            // Network errors are expected while offline; NetworkMonitor triggers recovery.
        }
    }

    func setStatus(_ status: ManualStatus) async throws {
        try await backend.rpcVoid("set_manual_status", ["p_status": .string(status.rawValue)])
    }

    /// Best effort, bounded so sleep / quit is never delayed by a slow network.
    func goOffline(timeout: Duration = .seconds(2)) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [backend] in try? await backend.rpcVoid("go_offline") }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
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
        guard backend.currentUserID != nil else { return }
        hub.restart()
        stop()
        start()
        onRecovered?()
    }
}
