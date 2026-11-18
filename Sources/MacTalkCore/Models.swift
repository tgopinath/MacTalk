import Foundation

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

public struct UserProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var email: String
    public var displayName: String?
    public var avatarURL: String?
    public var presenceStatus: PresenceStatus
    public var manualStatus: ManualStatus
    public var profileCompleted: Bool
    public var lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case presenceStatus = "presence_status"
        case manualStatus = "manual_status"
        case profileCompleted = "profile_completed"
        case lastSeen = "last_seen"
    }

    public init(id: UUID, email: String, displayName: String? = nil, avatarURL: String? = nil,
                presenceStatus: PresenceStatus = .offline, manualStatus: ManualStatus = .online,
                profileCompleted: Bool = false, lastSeen: Date? = nil) {
        self.id = id; self.email = email; self.displayName = displayName; self.avatarURL = avatarURL
        self.presenceStatus = presenceStatus; self.manualStatus = manualStatus
        self.profileCompleted = profileCompleted; self.lastSeen = lastSeen
    }

    public var name: String { displayName?.nonEmpty ?? email }
}

public struct Friend: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var email: String
    public var displayName: String?
    public var avatarURL: String?
    public var presenceStatus: PresenceStatus
    public var lastSeen: Date?

    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case presenceStatus = "presence_status"
        case lastSeen = "last_seen"
    }

    public init(id: UUID, email: String, displayName: String? = nil, avatarURL: String? = nil,
                presenceStatus: PresenceStatus = .offline, lastSeen: Date? = nil) {
        self.id = id; self.email = email; self.displayName = displayName; self.avatarURL = avatarURL
        self.presenceStatus = presenceStatus; self.lastSeen = lastSeen
    }

    public var name: String { displayName?.nonEmpty ?? email }

    /// Presence as it should be shown *now*: a friend whose heartbeat went quiet is offline
    /// even if the last Realtime row we received still says online.
    public func effectivePresence(now: Date = Date()) -> PresenceStatus {
        PresenceResolver.effective(status: presenceStatus, lastSeen: lastSeen, now: now)
    }
}

public enum FriendRequestDirection: String, Codable, Sendable { case incoming, outgoing }
public enum FriendRequestStatus: String, Codable, Sendable { case pending, accepted, declined, cancelled }

public struct FriendRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var direction: FriendRequestDirection
    public var status: FriendRequestStatus
    public var otherID: UUID
    public var otherEmail: String
    public var otherDisplayName: String?
    public var otherAvatarURL: String?
    public var createdAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, direction, status
        case otherID = "other_id"
        case otherEmail = "other_email"
        case otherDisplayName = "other_display_name"
        case otherAvatarURL = "other_avatar_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(id: UUID, direction: FriendRequestDirection, status: FriendRequestStatus, otherID: UUID,
                otherEmail: String, otherDisplayName: String? = nil, otherAvatarURL: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.direction = direction; self.status = status; self.otherID = otherID
        self.otherEmail = otherEmail; self.otherDisplayName = otherDisplayName
        self.otherAvatarURL = otherAvatarURL; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

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

public struct BlockedUser: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var email: String
    public var displayName: String?
    public var avatarURL: String?
    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
    public init(id: UUID, email: String, displayName: String? = nil, avatarURL: String? = nil) {
        self.id = id; self.email = email; self.displayName = displayName; self.avatarURL = avatarURL
    }
    public var name: String { displayName?.nonEmpty ?? email }
}

public enum CallRecordStatus: String, Codable, Sendable {
    case ringing, accepted, connecting, connected, declined, missed, busy, cancelled, ended, failed

    public var isActive: Bool { [.ringing, .accepted, .connecting, .connected].contains(self) }
}

public struct CallRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var callerID: UUID
    public var receiverID: UUID
    public var status: CallRecordStatus
    public var endReason: String?
    public var createdAt: Date
    public var expiresAt: Date
    public var startedAt: Date?
    public var acceptedAt: Date?
    public var endedAt: Date?
    public var duration: Int?

    enum CodingKeys: String, CodingKey {
        case id, status, duration
        case callerID = "caller_id"
        case receiverID = "receiver_id"
        case endReason = "end_reason"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case startedAt = "started_at"
        case acceptedAt = "accepted_at"
        case endedAt = "ended_at"
    }

    public init(id: UUID, callerID: UUID, receiverID: UUID, status: CallRecordStatus, endReason: String? = nil,
                createdAt: Date = Date(), expiresAt: Date = Date().addingTimeInterval(45),
                startedAt: Date? = nil, acceptedAt: Date? = nil, endedAt: Date? = nil, duration: Int? = nil) {
        self.id = id; self.callerID = callerID; self.receiverID = receiverID; self.status = status
        self.endReason = endReason; self.createdAt = createdAt; self.expiresAt = expiresAt
        self.startedAt = startedAt; self.acceptedAt = acceptedAt; self.endedAt = endedAt; self.duration = duration
    }

    public func isExpired(now: Date = Date()) -> Bool { status == .ringing && expiresAt <= now }
}

public struct CallPeer: Codable, Sendable, Equatable {
    public var id: UUID
    public var displayName: String?
    public var avatarURL: String?
    public var email: String?
    enum CodingKeys: String, CodingKey {
        case id, email
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
    public init(id: UUID, displayName: String?, avatarURL: String?, email: String?) {
        self.id = id; self.displayName = displayName; self.avatarURL = avatarURL; self.email = email
    }
    public init(friend: Friend) {
        self.init(id: friend.id, displayName: friend.displayName, avatarURL: friend.avatarURL, email: friend.email)
    }
    public var name: String { displayName?.nonEmpty ?? email ?? "Unknown" }
}

extension String {
    public var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
