import AppKit
import Foundation
import MacTalkCore
import Observation

/// Friends, invitations and blocking on the Realtime Database.
///
/// Layout (all under `mactalk/`):
/// - `u/{uid}/friends/{friendUid}`  : `{since}`, both directions written atomically on accept
/// - `inbox/{emailKey}/{fromUid}`   : invitations addressed to an email (readable only by its owner)
/// - `u/{uid}/outbox/{emailKey}`    : the sender's copy, so they can see accepted / declined
/// - `u/{uid}/blocks/{uid}`         : people you blocked
/// - `users/{uid}`                  : profile + presence, readable only by friends
@MainActor @Observable
final class FriendsService {
    private(set) var friends: [Friend] = []
    private(set) var requests: [FriendRequest] = []
    private(set) var blocked: [BlockedUser] = []
    private(set) var isLoading = false
    private(set) var loadError: MacTalkError?

    private let backend: Backend
    private var friendSince: [UserID: Date] = [:]
    private var records: [UserID: UserRecord] = [:]
    private var inbox: [UserID: InboxEntry] = [:]
    private var outbox: [String: OutboxEntry] = [:]
    private var blockedIDs: [UserID: BlockedUser] = [:]

    init(backend: Backend) { self.backend = backend }

    var incomingRequests: [FriendRequest] { requests.filter { $0.direction == .incoming && $0.status == .pending } }
    var outgoingRequests: [FriendRequest] { requests.filter { $0.direction == .outgoing && $0.status != .accepted } }

    func friend(id: UserID) -> Friend? { friends.first { $0.id == id } }

    // MARK: Live data from RealtimeHub

    /// `u/{me}` changed: friends, outbox and blocks.
    func apply(userNode: [String: Any]?) {
        friendSince = [:]
        for (uid, value) in (userNode?["friends"] as? [String: Any]) ?? [:] {
            let since = ((value as? [String: Any])?["since"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            friendSince[uid] = since ?? Date()
        }
        outbox = [:]
        for (key, value) in (userNode?["outbox"] as? [String: Any]) ?? [:] {
            if let entry: OutboxEntry = JSONTree.decode(value) { outbox[key] = entry }
        }
        blockedIDs = [:]
        for (uid, value) in (userNode?["blocks"] as? [String: Any]) ?? [:] {
            let info = value as? [String: Any]
            blockedIDs[uid] = BlockedUser(id: uid, email: info?["email"] as? String ?? "",
                                          displayName: info?["name"] as? String, avatarURL: info?["photo"] as? String)
        }
        blocked = Array(blockedIDs.values).sorted { $0.name < $1.name }
        // Fetch profiles for friends we haven't seen yet.
        let missing = friendSince.keys.filter { records[$0] == nil }
        rebuild()
        if !missing.isEmpty { Task { await refreshPresence(only: Array(missing)) } }
    }

    /// `inbox/{myEmailKey}` changed.
    func apply(inboxNode: [String: Any]?) {
        inbox = [:]
        for (uid, value) in inboxNode ?? [:] {
            if let entry: InboxEntry = JSONTree.decode(value) { inbox[uid] = entry }
        }
        rebuild()
    }

    /// Re-reads friends' profiles / presence (called every heartbeat).
    func refreshPresence(only ids: [UserID]? = nil) async {
        let targets = ids ?? Array(friendSince.keys)
        let db = backend.db
        let fetches = targets.map { id in
            (id, Task { @MainActor () -> UserRecord?? in
                do { return .some(try await db.get("users/\(id)", as: UserRecord.self)) } catch { return .none }
            })
        }
        for (id, task) in fetches {
            if let result = await task.value { records[id] = result ?? UserRecord() }
        }
        loadError = nil
        rebuild()
    }

    private func rebuild() {
        let now = Date()
        friends = friendSince.keys.filter { blockedIDs[$0] == nil }.map { id in
            Friend(id: id, record: records[id] ?? UserRecord(), since: friendSince[id], now: now)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var list: [FriendRequest] = []
        for (uid, entry) in inbox where blockedIDs[uid] == nil && friendSince[uid] == nil {
            list.append(FriendRequest(direction: .incoming, status: entry.status, otherID: uid, otherEmail: entry.fromEmail,
                                      otherDisplayName: entry.fromName, otherAvatarURL: entry.fromPhoto,
                                      createdAt: entry.createdAt ?? now, updatedAt: entry.updatedAt ?? now))
        }
        for (_, entry) in outbox {
            list.append(FriendRequest(direction: .outgoing, status: entry.status, otherID: nil, otherEmail: entry.toEmail,
                                      createdAt: entry.createdAt ?? now, updatedAt: entry.updatedAt ?? now))
        }
        requests = list.sorted { $0.updatedAt > $1.updatedAt }
        isLoading = false
    }

    func setLoading() { if friends.isEmpty { isLoading = true } }

    // MARK: Actions

    /// Returns a message suitable for showing to the user.
    func invite(email: String, myName: String, myPhoto: String?) async throws -> String {
        guard let me = backend.currentUserID, let myEmail = backend.currentEmail else { throw MacTalkError.notAuthenticated }
        let normalized = EmailValidator.normalize(email)
        guard EmailValidator.isValid(normalized) else { throw MacTalkError.invalidEmail }
        guard normalized != myEmail else { throw MacTalkError.server("That's your own email address.") }
        if friends.contains(where: { $0.email == normalized }) { return "You're already friends." }
        if let (uid, _) = inbox.first(where: { $0.value.fromEmail == normalized && $0.value.status == .pending }) {
            try await respond(incomingFrom: uid, accept: true)
            return "\(normalized) had already invited you. You're now friends."
        }
        let key = EmailKey.of(normalized)
        if outbox[key]?.status == .pending {
            return "An invitation to \(normalized) is already waiting. You can resend it from Manage Friends."
        }
        let ts = RealtimeDatabase.serverTimestamp
        do {
            try await backend.db.update([
                "inbox/\(key)/\(me)": ["fromName": myName, "fromPhoto": myPhoto ?? NSNull(), "fromEmail": myEmail,
                                       "status": "pending", "createdAt": ts, "updatedAt": ts],
                "u/\(me)/outbox/\(key)": ["toEmail": normalized, "status": "pending", "createdAt": ts, "updatedAt": ts],
            ])
        } catch { throw Backend.map(error) }
        return "Invitation sent to \(normalized). They'll see it when they sign in to MacTalk with that Google account."
    }

    /// Opens the user's mail app with a ready-to-send invitation email.
    func composeInvitationEmail(to email: String, fromName: String) {
        let subject = "\(fromName) wants to talk on MacTalk"
        let body = """
        Hi! I'd like to add you on MacTalk, a walkie-talkie for the Mac menu bar.

        1. Download MacTalk: https://github.com/tgopinath/MacTalk/releases/latest/download/MacTalk.dmg
        2. Open it and sign in with Google using \(email).
        3. Accept my invitation, then we can call each other with one click.

        – \(fromName)
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    func respond(_ request: FriendRequest, accept: Bool) async throws {
        guard let uid = request.otherID else { return }
        try await respond(incomingFrom: uid, accept: accept)
    }

    private func respond(incomingFrom uid: UserID, accept: Bool) async throws {
        guard let me = backend.currentUserID, let myKey = backend.myEmailKey else { throw MacTalkError.notAuthenticated }
        let ts = RealtimeDatabase.serverTimestamp
        var values: [String: Any] = [
            "inbox/\(myKey)/\(uid)": NSNull(),
            "u/\(uid)/outbox/\(myKey)/status": accept ? "accepted" : "declined",
            "u/\(uid)/outbox/\(myKey)/updatedAt": ts,
        ]
        if accept {
            values["u/\(me)/friends/\(uid)"] = ["since": ts]
            values["u/\(uid)/friends/\(me)"] = ["since": ts]
        }
        do { try await backend.db.update(values) } catch { throw Backend.map(error) }
    }

    func cancel(_ request: FriendRequest) async throws {
        guard let me = backend.currentUserID else { return }
        let key = EmailKey.of(request.otherEmail)
        var values: [String: Any] = ["u/\(me)/outbox/\(key)": NSNull()]
        if request.status == .pending { values["inbox/\(key)/\(me)"] = NSNull() }
        do { try await backend.db.update(values) } catch { throw Backend.map(error) }
    }

    func resend(_ request: FriendRequest, fromName: String) async throws -> String {
        guard let me = backend.currentUserID else { return "" }
        let key = EmailKey.of(request.otherEmail)
        try? await backend.db.update(["inbox/\(key)/\(me)/updatedAt": RealtimeDatabase.serverTimestamp,
                                      "u/\(me)/outbox/\(key)/updatedAt": RealtimeDatabase.serverTimestamp])
        composeInvitationEmail(to: request.otherEmail, fromName: fromName)
        return "Your mail app is open with the invitation to \(request.otherEmail)."
    }

    func remove(_ friendID: UserID) async throws {
        guard let me = backend.currentUserID else { return }
        do {
            try await backend.db.update(["u/\(me)/friends/\(friendID)": NSNull(), "u/\(friendID)/friends/\(me)": NSNull()])
        } catch { throw Backend.map(error) }
    }

    func block(_ userID: UserID) async throws {
        guard let me = backend.currentUserID, let myKey = backend.myEmailKey else { return }
        let f = friend(id: userID)
        let entry = inbox[userID]
        let info: [String: Any] = ["email": f?.email ?? entry?.fromEmail ?? "", "name": f?.displayName ?? entry?.fromName ?? NSNull(),
                                   "photo": f?.avatarURL ?? entry?.fromPhoto ?? NSNull(), "at": RealtimeDatabase.serverTimestamp]
        do {
            try await backend.db.update([
                "u/\(me)/blocks/\(userID)": info,
                "u/\(me)/friends/\(userID)": NSNull(),
                "u/\(userID)/friends/\(me)": NSNull(),
                "inbox/\(myKey)/\(userID)": NSNull(),
            ])
        } catch { throw Backend.map(error) }
    }

    func unblock(_ userID: UserID) async throws {
        guard let me = backend.currentUserID else { return }
        do { try await backend.db.delete("u/\(me)/blocks/\(userID)") } catch { throw Backend.map(error) }
    }

    func reset() {
        friends = []; requests = []; blocked = []
        friendSince = [:]; records = [:]; inbox = [:]; outbox = [:]; blockedIDs = [:]
    }

    #if DEBUG
    func debugSet(friends: [Friend], requests: [FriendRequest]) { self.friends = friends; self.requests = requests; loadError = nil }
    #endif
}
