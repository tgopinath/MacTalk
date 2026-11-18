import Foundation

public enum PresenceResolver {
    /// Heartbeats are sent every 25 s; after 60 s of silence a user is considered offline.
    public static let staleAfter: TimeInterval = 60
    public static let heartbeatInterval: TimeInterval = 25

    public static func effective(status: PresenceStatus, lastSeen: Date?, now: Date = Date()) -> PresenceStatus {
        guard let lastSeen, now.timeIntervalSince(lastSeen) < staleAfter else { return .offline }
        return status
    }

    /// Sort order for the friend list: reachable people first, then alphabetical.
    public static func rank(_ status: PresenceStatus) -> Int {
        switch status {
        case .online: 0
        case .busy: 1
        case .inCall: 2
        case .dnd: 3
        case .offline: 4
        }
    }
}
