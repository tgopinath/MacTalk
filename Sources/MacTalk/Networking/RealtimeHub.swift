import Foundation
import MacTalkCore
import Supabase

/// One Realtime channel per signed-in user carrying every live event MacTalk needs:
/// incoming calls, call status changes, friend requests, friendships and friend presence.
/// Every event is filtered server-side by Row Level Security.
@MainActor
final class RealtimeHub {
    struct UserRow: Decodable, Sendable {
        let id: UUID
        let display_name: String?
        let avatar_url: String?
        let presence_status: PresenceStatus
        let last_seen: Date?
    }

    var onCall: ((CallRecord) -> Void)?
    var onFriendRequests: (() -> Void)?
    var onFriendships: (() -> Void)?
    var onUserRow: ((UserRow) -> Void)?
    /// Called after (re)subscribing, so callers can catch up on anything missed while offline.
    var onResubscribed: (() -> Void)?

    private(set) var isConnected = false
    private let backend: Backend
    private var channel: RealtimeChannelV2?
    private var tasks: [Task<Void, Never>] = []
    private var userID: UUID?
    private var backoff = Backoff(base: 1, cap: 30)
    private var reconnectTask: Task<Void, Never>?

    init(backend: Backend) { self.backend = backend }

    func start(userID: UUID) async {
        self.userID = userID
        await subscribe()
    }

    func stop() async {
        userID = nil
        reconnectTask?.cancel()
        await teardown()
    }

    /// Drops and rebuilds the socket (after wake, network change or token refresh).
    func restart() {
        guard userID != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.teardown()
            await self?.subscribe()
        }
    }

    private func teardown() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        if let channel { await backend.client.removeChannel(channel) }
        channel = nil
        isConnected = false
    }

    private func subscribe() async {
        guard let uid = userID else { return }
        if let token = backend.client.auth.currentSession?.accessToken {
            await backend.client.realtimeV2.setAuth(token)
        }
        let channel = backend.client.channel("mactalk-user-\(uid.uuidString.lowercased())")
        let incoming = channel.postgresChange(InsertAction.self, table: "calls", filter: .eq("receiver_id", value: uid))
        let asReceiver = channel.postgresChange(UpdateAction.self, table: "calls", filter: .eq("receiver_id", value: uid))
        let asCaller = channel.postgresChange(UpdateAction.self, table: "calls", filter: .eq("caller_id", value: uid))
        let requestsIn = channel.postgresChange(AnyAction.self, table: "friend_requests", filter: .eq("receiver_id", value: uid))
        let requestsOut = channel.postgresChange(AnyAction.self, table: "friend_requests", filter: .eq("sender_id", value: uid))
        let friendships = channel.postgresChange(AnyAction.self, table: "friendships", filter: .eq("user_id", value: uid))
        let users = channel.postgresChange(UpdateAction.self, table: "users")

        let decoder = Backend.decoder
        tasks = [
            Task { [weak self] in for await a in incoming { self?.deliverCall(try? a.decodeRecord(decoder: decoder)) } },
            Task { [weak self] in for await a in asReceiver { self?.deliverCall(try? a.decodeRecord(decoder: decoder)) } },
            Task { [weak self] in for await a in asCaller { self?.deliverCall(try? a.decodeRecord(decoder: decoder)) } },
            Task { [weak self] in for await _ in requestsIn { self?.onFriendRequests?() } },
            Task { [weak self] in for await _ in requestsOut { self?.onFriendRequests?() } },
            Task { [weak self] in for await _ in friendships { self?.onFriendships?() } },
            Task { [weak self] in
                for await a in users { if let row: UserRow = try? a.decodeRecord(decoder: decoder) { self?.onUserRow?(row) } }
            },
        ]
        self.channel = channel

        do {
            try await channel.subscribeWithError()
            isConnected = true
            backoff.reset()
            watch(channel)
            onResubscribed?()
        } catch {
            isConnected = false
            scheduleReconnect()
        }
    }

    private func watch(_ channel: RealtimeChannelV2) {
        tasks.append(Task { [weak self] in
            for await status in channel.statusChange {
                guard let self else { return }
                if status == .unsubscribed, self.userID != nil, self.channel === channel {
                    self.isConnected = false
                    self.scheduleReconnect()
                    return
                }
            }
        })
    }

    private func scheduleReconnect() {
        guard userID != nil else { return }
        let delay = backoff.nextDelay()
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.teardown()
            await self?.subscribe()
        }
    }

    private func deliverCall(_ record: CallRecord?) {
        if let record { onCall?(record) }
    }

    // MARK: Per-call signaling

    /// Subscribes to signaling rows addressed to this user for one call.
    func signals(callID: UUID, onRow: @escaping @MainActor (SignalRow) -> Void) async -> RealtimeChannelV2 {
        let channel = backend.client.channel("mactalk-call-\(callID.uuidString.lowercased())")
        let inserts = channel.postgresChange(InsertAction.self, table: "call_signals", filter: .eq("call_id", value: callID))
        let decoder = Backend.decoder
        let me = userID
        Task {
            for await action in inserts {
                if let row: SignalRow = try? action.decodeRecord(decoder: decoder), row.recipientID == me {
                    await MainActor.run { onRow(row) }
                }
            }
        }
        try? await channel.subscribeWithError()
        return channel
    }

    func remove(_ channel: RealtimeChannelV2) async {
        await backend.client.removeChannel(channel)
    }
}
