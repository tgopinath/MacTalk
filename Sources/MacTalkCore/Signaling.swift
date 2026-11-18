import Foundation

public enum SignalKind: String, Codable, Sendable { case offer, answer, ice, restart, bye }

/// Row of `public.call_signals`.
public struct SignalRow: Codable, Sendable, Equatable {
    public var id: Int?
    public var callID: UUID
    public var senderID: UUID
    public var recipientID: UUID
    public var kind: SignalKind
    public var payload: SignalPayload

    enum CodingKeys: String, CodingKey {
        case id, kind, payload
        case callID = "call_id"
        case senderID = "sender_id"
        case recipientID = "recipient_id"
    }

    public init(id: Int? = nil, callID: UUID, senderID: UUID, recipientID: UUID, kind: SignalKind, payload: SignalPayload) {
        self.id = id; self.callID = callID; self.senderID = senderID; self.recipientID = recipientID
        self.kind = kind; self.payload = payload
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
/// de-duplicates signal rows delivered by both Realtime and the catch-up fetch.
public struct SignalInbox: Sendable {
    public private(set) var lastProcessedID: Int = 0
    public private(set) var pendingCandidates: [SignalPayload] = []
    private var seen: Set<Int> = []

    public init() {}

    /// Returns false if this row was already handled.
    public mutating func accept(_ row: SignalRow) -> Bool {
        guard let id = row.id else { return true }
        guard seen.insert(id).inserted else { return false }
        lastProcessedID = max(lastProcessedID, id)
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
