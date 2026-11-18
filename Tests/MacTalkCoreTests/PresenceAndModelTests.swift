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
        let f = Friend(id: UUID(), email: "a@b.co", presenceStatus: .online, lastSeen: Date().addingTimeInterval(-120))
        XCTAssertEqual(f.effectivePresence(), .offline)
        XCTAssertEqual(f.name, "a@b.co", "falls back to email when there is no display name")
    }

    func testFriendRequestStates() {
        let base = FriendRequest(id: UUID(), direction: .outgoing, status: .pending, otherID: UUID(), otherEmail: "x@y.z")
        XCTAssertEqual(base.displayState, "Invitation sent")
        var incoming = base; incoming.direction = .incoming
        XCTAssertEqual(incoming.displayState, "Invitation received")
        var declined = base; declined.status = .declined
        XCTAssertEqual(declined.displayState, "Declined")
    }

    func testDecodesServerRows() throws {
        let json = """
        {"id":"6f1d2c1e-0b7a-4b8e-9d55-1f2a3b4c5d6e","caller_id":"0a0a0a0a-0000-4000-8000-000000000001",
         "receiver_id":"0a0a0a0a-0000-4000-8000-000000000002","status":"ringing","end_reason":null,
         "created_at":"2026-11-18T10:00:00Z","expires_at":"2026-11-18T10:00:45Z","started_at":null,
         "accepted_at":null,"ended_at":null,"duration":null}
        """.data(using: .utf8)!
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let call = try d.decode(CallRecord.self, from: json)
        XCTAssertEqual(call.status, .ringing)
        XCTAssertTrue(call.status.isActive)
        XCTAssertTrue(call.isExpired(now: call.expiresAt.addingTimeInterval(1)))
        XCTAssertFalse(call.isExpired(now: call.createdAt))
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
        XCTAssertFalse(AppConfiguration(infoDictionary: ["MacTalkSupabaseURL": "https://x.supabase.co",
                                                         "MacTalkSupabaseAnonKey": "YOUR_ANON_KEY_GOES_HERE_PLEASE"]).isConfigured)
        XCTAssertFalse(AppConfiguration(infoDictionary: ["MacTalkSupabaseURL": "http://x.supabase.co",
                                                         "MacTalkSupabaseAnonKey": String(repeating: "k", count: 40)]).isConfigured,
                       "plain http is rejected")
        let ok = AppConfiguration(infoDictionary: ["MacTalkSupabaseURL": "https://x.supabase.co",
                                                   "MacTalkSupabaseAnonKey": String(repeating: "k", count: 40),
                                                   "MacTalkEnvironment": "staging"])
        XCTAssertTrue(ok.isConfigured)
        XCTAssertEqual(ok.environment, .staging)
    }

    func testConnectionQuality() {
        XCTAssertEqual(ConnectionQuality.rate(roundTripTime: nil, lossRatio: nil, jitter: nil), .unknown)
        XCTAssertEqual(ConnectionQuality.rate(roundTripTime: 0.04, lossRatio: 0, jitter: 0.005), .excellent)
        XCTAssertEqual(ConnectionQuality.rate(roundTripTime: 0.18, lossRatio: 0.005, jitter: 0.01), .good)
        XCTAssertEqual(ConnectionQuality.rate(roundTripTime: 0.3, lossRatio: 0, jitter: 0), .fair)
        XCTAssertEqual(ConnectionQuality.rate(roundTripTime: 0.05, lossRatio: 0.2, jitter: 0), .poor)
    }
}
