import Foundation

/// The client-side lifecycle of one call, mirroring the states in the product spec.
public enum CallPhase: String, Sendable, Equatable, CaseIterable {
    case initiating, ringing, accepted, connecting, connected, reconnecting
    case declined, missed, busy, cancelled, ended, failed

    public var isTerminal: Bool {
        [.declined, .missed, .busy, .cancelled, .ended, .failed].contains(self)
    }

    /// True once the microphone may be captured. Never while ringing.
    public var allowsMedia: Bool { [.accepted, .connecting, .connected, .reconnecting].contains(self) }

    public var label: String {
        switch self {
        case .initiating: "Calling…"
        case .ringing: "Ringing…"
        case .accepted: "Accepted"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .declined: "Declined"
        case .missed: "No answer"
        case .busy: "Busy"
        case .cancelled: "Cancelled"
        case .ended: "Call ended"
        case .failed: "Call failed"
        }
    }
}

public enum CallDirection: Sendable, Equatable { case outgoing, incoming }

public struct CallStateMachine: Sendable, Equatable {
    public private(set) var phase: CallPhase
    public let direction: CallDirection

    public init(direction: CallDirection) {
        self.direction = direction
        self.phase = direction == .outgoing ? .initiating : .ringing
    }

    static let allowed: [CallPhase: Set<CallPhase>] = [
        .initiating: [.ringing, .busy, .failed, .cancelled],
        .ringing: [.accepted, .declined, .missed, .cancelled, .busy, .failed, .ended],
        .accepted: [.connecting, .connected, .ended, .failed],
        .connecting: [.connected, .ended, .failed],
        .connected: [.reconnecting, .ended, .failed],
        .reconnecting: [.connected, .ended, .failed],
    ]

    public func canTransition(to next: CallPhase) -> Bool {
        Self.allowed[phase]?.contains(next) ?? false
    }

    /// Applies a transition; invalid or out-of-order events (common with Realtime +
    /// polling delivering the same change twice) are ignored and return false.
    @discardableResult
    public mutating func transition(to next: CallPhase) -> Bool {
        guard next != phase, canTransition(to: next) else { return false }
        phase = next
        return true
    }

    /// Maps a server call row onto the local phase.
    @discardableResult
    public mutating func apply(serverStatus: CallRecordStatus) -> Bool {
        let next: CallPhase = switch serverStatus {
        case .ringing: .ringing
        case .accepted: .accepted
        case .connecting: .connecting
        case .connected: .connected
        case .declined: .declined
        case .missed: .missed
        case .busy: .busy
        case .cancelled: .cancelled
        case .ended: .ended
        case .failed: .failed
        }
        // Server "connecting/connected" lags the local media state; never move backwards.
        if next == .connecting, [.connected, .reconnecting].contains(phase) { return false }
        if next == .connected, phase == .reconnecting { return false }
        return transition(to: next)
    }
}

public enum CallDurationFormatter {
    public static func string(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
