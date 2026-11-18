import Foundation

public enum ConnectionQuality: Int, Sendable, Comparable, CaseIterable {
    case unknown = 0, poor, fair, good, excellent

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .unknown: "Measuring…"
        case .poor: "Poor connection"
        case .fair: "Fair connection"
        case .good: "Good connection"
        case .excellent: "Excellent connection"
        }
    }

    /// Number of filled bars (0…4).
    public var bars: Int { rawValue }

    /// Rates a call from WebRTC stats: round-trip time (s), packet loss ratio (0…1), jitter (s).
    public static func rate(roundTripTime rtt: Double?, lossRatio: Double?, jitter: Double?) -> ConnectionQuality {
        guard rtt != nil || lossRatio != nil else { return .unknown }
        let rttMs = (rtt ?? 0) * 1000, loss = (lossRatio ?? 0) * 100, jitterMs = (jitter ?? 0) * 1000
        if rttMs > 500 || loss > 10 || jitterMs > 100 { return .poor }
        if rttMs > 250 || loss > 3 || jitterMs > 50 { return .fair }
        if rttMs > 120 || loss > 1 || jitterMs > 20 { return .good }
        return .excellent
    }
}
