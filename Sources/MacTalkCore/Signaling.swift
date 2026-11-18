import Foundation

public enum SignalKind: String, Codable, Sendable { case offer, answer, ice, restart, bye }

/// `mactalk/calls/{callId}/signals/{pushKey}`. Push keys sort chronologically.
public struct SignalRow: Codable, Sendable, Equatable {
    public var key: String?
    public var from: UserID
    public var kind: SignalKind
    public var payload: SignalPayload

    enum CodingKeys: String, CodingKey { case from, kind, payload }

    public init(key: String? = nil, from: UserID, kind: SignalKind, payload: SignalPayload) {
        self.key = key; self.from = from; self.kind = kind; self.payload = payload
    }
}

public struct SignalPayload: Codable, Sendable, Equatable {
    public var sdp: String?
    public var candidate: String?
    public var sdpMid: String?
    public var sdpMLineIndex: Int32?

    public init(sdp: String? = nil, candidate: String? = nil, sdpMid: String? = nil, sdpMLineIndex: Int32? = nil) {
        self.sdp = sdp; self.candidate = candidate; self.sdpMid = sdpMid; self.sdpMLineIndex = sdpMLineIndex
    }

    public static func description(_ sdp: String) -> SignalPayload { .init(sdp: sdp) }
    public static func ice(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) -> SignalPayload {
        .init(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
    }
}

/// Holds remote ICE candidates that arrive before the remote description is set, and
/// de-duplicates signal rows delivered by both the live stream and the catch-up fetch.
public struct SignalInbox: Sendable {
    public private(set) var lastProcessedKey: String = ""
    public private(set) var pendingCandidates: [SignalPayload] = []
    private var seen: Set<String> = []

    public init() {}

    /// Returns false if this row was already handled.
    public mutating func accept(_ row: SignalRow) -> Bool {
        guard let key = row.key else { return true }
        guard seen.insert(key).inserted else { return false }
        lastProcessedKey = max(lastProcessedKey, key)
        return true
    }

    public mutating func buffer(_ candidate: SignalPayload) { pendingCandidates.append(candidate) }

    public mutating func drainCandidates() -> [SignalPayload] {
        defer { pendingCandidates.removeAll() }
        return pendingCandidates
    }
}

/// Exponential back-off used for Realtime resubscription and ICE restarts.
public struct Backoff: Sendable {
    public var attempt = 0
    public let base: TimeInterval
    public let cap: TimeInterval

    public init(base: TimeInterval = 1, cap: TimeInterval = 30) { self.base = base; self.cap = cap }

    public mutating func nextDelay() -> TimeInterval {
        defer { attempt += 1 }
        return min(cap, base * pow(2, Double(attempt)))
    }

    public mutating func reset() { attempt = 0 }
}
