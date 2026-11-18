import XCTest
@testable import MacTalkCore

final class SignalingAndErrorTests: XCTestCase {
    private func row(_ key: String, _ kind: SignalKind = .ice) -> SignalRow {
        SignalRow(key: key, from: "peer", kind: kind, payload: .ice(candidate: "candidate:\(key)", sdpMid: "0", sdpMLineIndex: 0))
    }

    func testInboxDeduplicatesRealtimeAndCatchUp() {
        var inbox = SignalInbox()
        XCTAssertTrue(inbox.accept(row("-Na1")))
        XCTAssertTrue(inbox.accept(row("-Na2")))
        XCTAssertFalse(inbox.accept(row("-Na1")), "row already delivered by the live stream")
        XCTAssertEqual(inbox.lastProcessedKey, "-Na2")
    }

    func testCandidatesBufferUntilRemoteDescription() {
        var inbox = SignalInbox()
        inbox.buffer(.ice(candidate: "a", sdpMid: "0", sdpMLineIndex: 0))
        inbox.buffer(.ice(candidate: "b", sdpMid: "0", sdpMLineIndex: 0))
        XCTAssertEqual(inbox.drainCandidates().map(\.candidate), ["a", "b"])
        XCTAssertTrue(inbox.drainCandidates().isEmpty)
    }

    func testSignalRowEncodingOmitsPushKey() throws {
        let r = SignalRow(key: "-Nabc", from: "uidA", kind: .offer, payload: .description("v=0"))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        XCTAssertNil(json["key"], "the push key is the node name, not a field")
        XCTAssertEqual(json["kind"] as? String, "offer")
        XCTAssertEqual(json["from"] as? String, "uidA")
        XCTAssertEqual((json["payload"] as? [String: Any])?["sdp"] as? String, "v=0")
    }

    func testBackoffGrowsAndCaps() {
        var b = Backoff(base: 1, cap: 8)
        XCTAssertEqual((0..<6).map { _ in b.nextDelay() }, [1, 2, 4, 8, 8, 8])
        b.reset()
        XCTAssertEqual(b.nextDelay(), 1)
    }

    func testServerErrorCodesMapToFriendlyErrors() {
        XCTAssertEqual(MacTalkError.fromServer(message: "friend_offline", peerName: "Alex"), .friendOffline("Alex"))
        XCTAssertEqual(MacTalkError.fromServer(message: "friend_in_call", peerName: "Alex"), .friendInCall("Alex"))
        XCTAssertEqual(MacTalkError.fromServer(message: "friend_dnd", peerName: "Alex"), .friendDND("Alex"))
        XCTAssertEqual(MacTalkError.fromServer(message: "not_friends"), .notFriends)
        XCTAssertEqual(MacTalkError.fromServer(message: "rate_limited"), .rateLimited)
        XCTAssertEqual(MacTalkError.fromServer(message: "already_in_call"), .alreadyInCall)
        XCTAssertEqual(MacTalkError.fromServer(message: "email_not_verified"), .emailNotVerified)
        XCTAssertEqual(MacTalkError.fromServer(message: "JWT expired"), .sessionExpired)
        XCTAssertEqual(MacTalkError.fromServer(message: "call_expired"), .callExpired)
        XCTAssertEqual(MacTalkError.fromServer(message: "Permission denied"), .permissionDenied)
        XCTAssertEqual(MacTalkError.fromServer(message: "TOKEN_EXPIRED"), .sessionExpired)
        XCTAssertEqual(MacTalkError.fromServer(message: "something else"), .server("something else"))
        XCTAssertEqual(MacTalkError.friendOffline("Alex").errorDescription, "Alex is offline right now.")
    }
}
