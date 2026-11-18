import XCTest
@testable import MacTalkCore

final class PresenceAndModelTests: XCTestCase {
    func testStaleHeartbeatMeansOffline() {
        let now = Date()
        XCTAssertEqual(PresenceResolver.effective(status: .online, lastSeen: now.addingTimeInterval(-10), now: now), .online)
        XCTAssertEqual(PresenceResolver.effective(status: .online, lastSeen: now.addingTimeInterval(-61), now: now), .offline)
        XCTAssertEqual(PresenceResolver.effective(status: .busy, lastSeen: nil, now: now), .offline)
        XCTAssertEqual(PresenceResolver.effective(status: .inCall, lastSeen: now, now: now), .inCall)
    }

    func testOnlyOnlineFriendsAreCallable() {
        XCTAssertTrue(PresenceStatus.online.isCallable)
        for s in [PresenceStatus.offline, .busy, .dnd, .inCall] { XCTAssertFalse(s.isCallable, "\(s)") }
    }

    func testFriendEffectivePresence() {
        let f = Friend(id: "u1", email: "a@b.co", presenceStatus: .online, lastSeen: Date().addingTimeInterval(-120))
        XCTAssertEqual(f.effectivePresence(), .offline)
        XCTAssertEqual(f.name, "a@b.co", "falls back to email when there is no display name")
    }

    func testFriendRequestStates() {
        let base = FriendRequest(direction: .outgoing, status: .pending, otherID: nil, otherEmail: "x@y.z")
        XCTAssertEqual(base.displayState, "Invitation sent")
        var incoming = base; incoming.direction = .incoming
        XCTAssertEqual(incoming.displayState, "Invitation received")
        var declined = base; declined.status = .declined
        XCTAssertEqual(declined.displayState, "Declined")
    }

    func testDecodesDatabaseRecords() throws {
        let call = try JSONDecoder.firebase.decode(CallRecord.self, from: Data("""
        {"caller":"uidA","callee":"uidB","callerName":"Alex","status":"ringing",
         "createdAt":1795000000000,"expiresAt":1795000045000}
        """.utf8))
        XCTAssertEqual(call.status, .ringing)
        XCTAssertEqual(call.caller, "uidA")
        XCTAssertTrue(call.isExpired(now: call.expiresAt.addingTimeInterval(1)))
        XCTAssertFalse(call.isExpired(now: call.createdAt!))

        let ring = try JSONDecoder.firebase.decode(RingEntry.self, from: Data(#"{"caller":"uidA","expiresAt":1795000045000}"#.utf8))
        XCTAssertEqual(ring.expiresAt, call.expiresAt)
    }

    func testUserRecordPresence() {
        let now = Date()
        XCTAssertEqual(UserRecord(status: .online, online: true, lastSeen: now).presence(now: now), .online)
        XCTAssertEqual(UserRecord(status: .online, online: false, lastSeen: now).presence(now: now), .offline, "quit / signed out")
        XCTAssertEqual(UserRecord(status: .online, online: true, lastSeen: now.addingTimeInterval(-90)).presence(now: now), .offline, "stale heartbeat")
        XCTAssertEqual(UserRecord(status: .dnd, online: true, lastSeen: now).presence(now: now), .dnd)
        XCTAssertEqual(UserRecord(status: .online, online: true, lastSeen: now,
                                  inCall: .init(callId: "c1", at: now)).presence(now: now), .inCall)
        XCTAssertEqual(UserRecord(status: .online, online: true, lastSeen: now,
                                  inCall: .init(callId: "c1", at: now.addingTimeInterval(-200))).presence(now: now), .online,
                       "an old in-call marker from a crash is ignored")
    }

    func testEmailKeysMatchDatabaseRules() {
        XCTAssertEqual(EmailKey.of(" Alex.J@Gmail.com "), "alex,j@gmail,com")
    }

    func testEmailValidation() {
        XCTAssertTrue(EmailValidator.isValid("alex@example.com"))
        XCTAssertTrue(EmailValidator.isValid("  a.b+c@sub.example.co  "))
        for bad in ["", "alex", "alex@", "@example.com", "alex@example", "a b@example.com", "alex@exa mple.com", "a@b@c.com", "a@.com"] {
            XCTAssertFalse(EmailValidator.isValid(bad), bad)
        }
        XCTAssertEqual(EmailValidator.normalize("  Alex@Example.COM "), "alex@example.com")
    }

    func testInitials() {
        XCTAssertEqual(Initials.of("Alex Johnson"), "AJ")
        XCTAssertEqual(Initials.of("alex.johnson@example.com"), "AJ")
        XCTAssertEqual(Initials.of("mia"), "M")
        XCTAssertEqual(Initials.of(""), "?")
    }

    func testConfigurationRequiresRealValues() {
        XCTAssertFalse(AppConfiguration(infoDictionary: [:]).isConfigured)
        let base: [String: Any] = ["MacTalkFirebaseAPIKey": String(repeating: "k", count: 39),
                                   "MacTalkDatabaseURL": "https://x-default-rtdb.firebaseio.com",
                                   "MacTalkAuthPageURL": "https://x.github.io/MacTalk/auth/",
                                   "MacTalkEnvironment": "staging", "MacTalkTurnURLs": "turn:a:3478, turns:b:5349"]
        let ok = AppConfiguration(infoDictionary: base)
        XCTAssertTrue(ok.isConfigured)
        XCTAssertEqual(ok.environment, .staging)
        XCTAssertEqual(ok.turnURLs, ["turn:a:3478", "turns:b:5349"])
        var placeholder = base; placeholder["MacTalkFirebaseAPIKey"] = "YOUR_FIREBASE_WEB_API_KEY_HERE"
        XCTAssertFalse(AppConfiguration(infoDictionary: placeholder).isConfigured)
        var http = base; http["MacTalkDatabaseURL"] = "http://x.firebaseio.com"
        XCTAssertFalse(AppConfiguration(infoDictionary: http).isConfigured, "plain http is rejected")
    }

    func testConnectionQuality() {
        XCTAssertEqual(ConnectionQuality.rate(roundTripTime: nil, lossRatio: nil, jitter: nil), .unknown)
        XCTAssertEqual(ConnectionQuality.rate(roundTripTime: 0.04, lossRatio: 0, jitter: 0.005), .excellent)
        XCTAssertEqual(ConnectionQuality.rate(roundTripTime: 0.18, lossRatio: 0.005, jitter: 0.01), .good)
        XCTAssertEqual(ConnectionQuality.rate(roundTripTime: 0.3, lossRatio: 0, jitter: 0), .fair)
        XCTAssertEqual(ConnectionQuality.rate(roundTripTime: 0.05, lossRatio: 0.2, jitter: 0), .poor)
    }
}
