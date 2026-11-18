import Foundation
import MacTalkCore
import Observation
import Supabase

/// Friends, invitations and blocking. Lists are refreshed from SQL functions and kept
/// live by Realtime events routed in from `RealtimeHub`.
@MainActor @Observable
final class FriendsService {
    private(set) var friends: [Friend] = []
    private(set) var requests: [FriendRequest] = []
    private(set) var blocked: [BlockedUser] = []
    private(set) var isLoading = false
    private(set) var loadError: MacTalkError?

    private let backend: Backend
    private var refreshTask: Task<Void, Never>?

    init(backend: Backend) { self.backend = backend }

    var incomingRequests: [FriendRequest] { requests.filter { $0.direction == .incoming && $0.status == .pending } }
    var outgoingRequests: [FriendRequest] { requests.filter { $0.direction == .outgoing } }

    func friend(id: UUID) -> Friend? { friends.first { $0.id == id } }

    func refreshAll() async {
        isLoading = friends.isEmpty
        defer { isLoading = false }
        do {
            async let f: [Friend] = backend.rpc("list_friends")
            async let r: [FriendRequest] = backend.rpc("list_friend_requests")
            async let b: [BlockedUser] = backend.rpc("list_blocked")
            (friends, requests, blocked) = try await (f, r, b)
            loadError = nil
        } catch {
            loadError = Backend.map(error)
        }
    }

    /// Coalesces bursts of Realtime events into one refresh.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refreshAll()
        }
    }

    /// Live presence update for one friend (from a Realtime `users` row).
    func applyPresence(userID: UUID, status: PresenceStatus, lastSeen: Date?, displayName: String?, avatarURL: String?) {
        guard let i = friends.firstIndex(where: { $0.id == userID }) else { return }
        friends[i].presenceStatus = status
        friends[i].lastSeen = lastSeen
        if let displayName { friends[i].displayName = displayName }
        friends[i].avatarURL = avatarURL
    }

    struct InviteResult: Decodable { let outcome: String; let email_delivered: Bool? }

    /// Returns a message suitable for showing to the user.
    func invite(email: String) async throws -> String {
        let normalized = EmailValidator.normalize(email)
        guard EmailValidator.isValid(normalized) else { throw MacTalkError.invalidEmail }
        let result: InviteResult
        do {
            result = try await backend.client.functions.invoke(
                "invite-friend", options: .init(body: ["action": "invite", "email": normalized]))
        } catch {
            throw mapFunctionError(error)
        }
        await refreshAll()
        switch result.outcome {
        case "accepted": return "You're now friends with \(normalized)."
        case "already_friends": return "You're already friends."
        case "already_pending": return "An invitation to \(normalized) is already waiting. You can resend it from Manage Friends."
        case "self": throw MacTalkError.server("That's your own email address.")
        default: return "Invitation sent to \(normalized)."
        }
    }

    func resend(_ request: FriendRequest) async throws -> String {
        let result: InviteResult
        do {
            result = try await backend.client.functions.invoke(
                "invite-friend", options: .init(body: ["action": "resend", "request_id": request.id.uuidString.lowercased()]))
        } catch {
            throw mapFunctionError(error)
        }
        return result.email_delivered == true
            ? "Invitation email sent again."
            : "Reminder recorded. \(request.otherName) will see your invitation when they open MacTalk."
    }

    func respond(_ request: FriendRequest, accept: Bool) async throws {
        try await backend.rpcVoid("respond_friend_request", ["p_request_id": .uuid(request.id), "p_accept": .bool(accept)])
        await refreshAll()
    }

    func cancel(_ request: FriendRequest) async throws {
        try await backend.rpcVoid("cancel_friend_request", ["p_request_id": .uuid(request.id)])
        await refreshAll()
    }

    func remove(_ friendID: UUID) async throws {
        try await backend.rpcVoid("remove_friend", ["p_friend_id": .uuid(friendID)])
        await refreshAll()
    }

    func block(_ userID: UUID) async throws {
        try await backend.rpcVoid("block_user", ["p_user_id": .uuid(userID)])
        await refreshAll()
    }

    func unblock(_ userID: UUID) async throws {
        try await backend.rpcVoid("unblock_user", ["p_user_id": .uuid(userID)])
        await refreshAll()
    }

    func reset() { friends = []; requests = []; blocked = [] }

    #if DEBUG
    func debugSet(friends: [Friend], requests: [FriendRequest]) { self.friends = friends; self.requests = requests; loadError = nil }
    #endif

    private func mapFunctionError(_ error: Error) -> MacTalkError {
        if case let FunctionsError.httpError(_, data) = error,
           let body = try? JSONDecoder().decode([String: String].self, from: data), let code = body["error"] {
            return .fromServer(message: code)
        }
        return Backend.map(error)
    }
}
