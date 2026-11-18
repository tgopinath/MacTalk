import Foundation

/// Firebase Auth uid.
public typealias UserID = String
/// Realtime Database push key of a call.
public typealias CallID = String

public enum PresenceStatus: String, Codable, Sendable, CaseIterable {
    case online, offline, busy, dnd
    case inCall = "in_call"

    public var label: String {
        switch self {
        case .online: "Online"
        case .offline: "Offline"
        case .busy: "Busy"
        case .dnd: "Do Not Disturb"
        case .inCall: "In a call"
        }
    }

    /// Whether a Call button should be enabled for a friend in this state.
    public var isCallable: Bool { self == .online }
}

/// The status a user can choose for themselves. Offline / in-call are derived.
public enum ManualStatus: String, Codable, Sendable, CaseIterable {
    case online, busy, dnd

    public var presence: PresenceStatus {
        switch self {
        case .online: .online
        case .busy: .busy
        case .dnd: .dnd
        }
    }
}

/// `mactalk/users/{uid}` in the Realtime Database.
public struct UserRecord: Codable, Sendable, Equatable {
    public struct InCall: Codable, Sendable, Equatable {
        public var callId: CallID
        public var at: Date
        public init(callId: CallID, at: Date) { self.callId = callId; self.at = at }
    }

    public var name: String?
    public var photo: String?
    public var email: String?
    public var status: ManualStatus?
    public var online: Bool?
    public var lastSeen: Date?
    public var inCall: InCall?

    public init(name: String? = nil, photo: String? = nil, email: String? = nil, status: ManualStatus? = nil,
                online: Bool? = nil, lastSeen: Date? = nil, inCall: InCall? = nil) {
        self.name = name; self.photo = photo; self.email = email; self.status = status
        self.online = online; self.lastSeen = lastSeen; self.inCall = inCall
    }

    /// Presence as friends should see it now.
    public func presence(now: Date = Date()) -> PresenceStatus {
        guard online == true else { return .offline }
        let p = PresenceResolver.effective(status: (status ?? .online).presence, lastSeen: lastSeen, now: now)
        if p != .offline, let inCall, now.timeIntervalSince(inCall.at) < PresenceResolver.inCallStaleAfter { return .inCall }
        return p
    }
}

public struct UserProfile: Sendable, Equatable, Identifiable {
    public var id: UserID
    public var email: String
    public var displayName: String?
    public var avatarURL: String?
    public var manualStatus: ManualStatus
    public var profileCompleted: Bool

    public init(id: UserID, email: String, displayName: String? = nil, avatarURL: String? = nil,
                manualStatus: ManualStatus = .online, profileCompleted: Bool = false) {
        self.id = id; self.email = email; self.displayName = displayName; self.avatarURL = avatarURL
        self.manualStatus = manualStatus; self.profileCompleted = profileCompleted
    }

    public var name: String { displayName?.nonEmpty ?? email }
}

public struct Friend: Sendable, Equatable, Identifiable, Hashable {
    public var id: UserID
    public var email: String
    public var displayName: String?
    public var avatarURL: String?
    public var presenceStatus: PresenceStatus
    public var lastSeen: Date?
    public var friendsSince: Date?

    public init(id: UserID, email: String, displayName: String? = nil, avatarURL: String? = nil,
                presenceStatus: PresenceStatus = .offline, lastSeen: Date? = nil, friendsSince: Date? = nil) {
        self.id = id; self.email = email; self.displayName = displayName; self.avatarURL = avatarURL
        self.presenceStatus = presenceStatus; self.lastSeen = lastSeen; self.friendsSince = friendsSince
    }

    public init(id: UserID, record: UserRecord, since: Date?, now: Date = Date()) {
        self.init(id: id, email: record.email ?? "", displayName: record.name, avatarURL: record.photo,
                  presenceStatus: record.presence(now: now), lastSeen: record.lastSeen, friendsSince: since)
    }

    public var name: String { displayName?.nonEmpty ?? (email.isEmpty ? "Friend" : email) }

    /// A friend whose heartbeat went quiet is offline even if the last fetch said online.
    public func effectivePresence(now: Date = Date()) -> PresenceStatus {
        PresenceResolver.effective(status: presenceStatus, lastSeen: lastSeen, now: now)
    }
}

public enum FriendRequestDirection: String, Codable, Sendable { case incoming, outgoing }
public enum FriendRequestStatus: String, Codable, Sendable { case pending, accepted, declined, cancelled }

public struct FriendRequest: Sendable, Equatable, Identifiable {
    public var direction: FriendRequestDirection
    public var status: FriendRequestStatus
    /// Sender uid for incoming requests; unknown (nil) for outgoing ones until accepted.
    public var otherID: UserID?
    public var otherEmail: String
    public var otherDisplayName: String?
    public var otherAvatarURL: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(direction: FriendRequestDirection, status: FriendRequestStatus, otherID: UserID?,
                otherEmail: String, otherDisplayName: String? = nil, otherAvatarURL: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.direction = direction; self.status = status; self.otherID = otherID
        self.otherEmail = otherEmail; self.otherDisplayName = otherDisplayName
        self.otherAvatarURL = otherAvatarURL; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public var id: String { "\(direction.rawValue):\(otherID ?? EmailKey.of(otherEmail))" }
    public var otherName: String { otherDisplayName?.nonEmpty ?? otherEmail }

    /// The friendship state as described in the product spec.
    public var displayState: String {
        switch (direction, status) {
        case (.outgoing, .pending): "Invitation sent"
        case (.incoming, .pending): "Invitation received"
        case (_, .accepted): "Accepted"
        case (_, .declined): "Declined"
        case (_, .cancelled): "Cancelled"
        }
    }
}

/// `mactalk/inbox/{emailKey}/{fromUid}`
public struct InboxEntry: Codable, Sendable, Equatable {
    public var fromName: String?
    public var fromPhoto: String?
    public var fromEmail: String
    public var status: FriendRequestStatus
    public var createdAt: Date?
    public var updatedAt: Date?
}

/// `mactalk/u/{uid}/outbox/{emailKey}`
public struct OutboxEntry: Codable, Sendable, Equatable {
    public var toEmail: String
    public var status: FriendRequestStatus
    public var createdAt: Date?
    public var updatedAt: Date?
}

public struct BlockedUser: Codable, Sendable, Equatable, Identifiable {
    public var id: UserID
    public var email: String
    public var displayName: String?
    public var avatarURL: String?
    public init(id: UserID, email: String, displayName: String? = nil, avatarURL: String? = nil) {
        self.id = id; self.email = email; self.displayName = displayName; self.avatarURL = avatarURL
    }
    public var name: String { displayName?.nonEmpty ?? email }
}

public enum CallRecordStatus: String, Codable, Sendable {
    case ringing, accepted, connecting, connected, declined, missed, busy, cancelled, ended, failed

    public var isActive: Bool { [.ringing, .accepted, .connecting, .connected].contains(self) }
}

/// `mactalk/calls/{callId}` (signals are a child list, decoded separately).
public struct CallRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: CallID = ""
    public var caller: UserID
    public var callee: UserID
    public var callerName: String?
    public var callerPhoto: String?
    public var status: CallRecordStatus
    public var createdAt: Date?
    public var expiresAt: Date
    public var acceptedAt: Date?
    public var connectedAt: Date?
    public var endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case caller, callee, callerName, callerPhoto, status, createdAt, expiresAt, acceptedAt, connectedAt, endedAt
    }

    public init(id: CallID, caller: UserID, callee: UserID, callerName: String? = nil, callerPhoto: String? = nil,
                status: CallRecordStatus, createdAt: Date? = Date(), expiresAt: Date = Date().addingTimeInterval(45),
                acceptedAt: Date? = nil, connectedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id; self.caller = caller; self.callee = callee; self.callerName = callerName
        self.callerPhoto = callerPhoto; self.status = status; self.createdAt = createdAt; self.expiresAt = expiresAt
        self.acceptedAt = acceptedAt; self.connectedAt = connectedAt; self.endedAt = endedAt
    }

    public func isExpired(now: Date = Date()) -> Bool { status == .ringing && expiresAt <= now }
}

/// `mactalk/u/{callee}/rings/{callId}`
public struct RingEntry: Codable, Sendable, Equatable {
    public var caller: UserID
    public var callerName: String?
    public var callerPhoto: String?
    public var expiresAt: Date
}

public struct CallPeer: Sendable, Equatable {
    public var id: UserID
    public var displayName: String?
    public var avatarURL: String?
    public var email: String?
    public init(id: UserID, displayName: String?, avatarURL: String?, email: String?) {
        self.id = id; self.displayName = displayName; self.avatarURL = avatarURL; self.email = email
    }
    public init(friend: Friend) {
        self.init(id: friend.id, displayName: friend.displayName, avatarURL: friend.avatarURL, email: friend.email)
    }
    public var name: String { displayName?.nonEmpty ?? email ?? "Unknown" }
}

/// Realtime Database keys can't contain `.`; emails are stored with `.` → `,`.
/// Must match `auth.token.email.toLowerCase().replace('.', ',')` in database.rules.json.
public enum EmailKey {
    public static func of(_ email: String) -> String {
        EmailValidator.normalize(email).replacingOccurrences(of: ".", with: ",")
    }
}

extension String {
    public var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension JSONDecoder {
    /// Realtime Database stores times as epoch milliseconds.
    public static var firebase: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}

extension JSONEncoder {
    public static var firebase: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }
}
