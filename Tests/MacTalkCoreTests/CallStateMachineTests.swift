import XCTest
@testable import MacTalkCore

final class CallStateMachineTests: XCTestCase {
    func testOutgoingHappyPath() {
        var m = CallStateMachine(direction: .outgoing)
        XCTAssertEqual(m.phase, .initiating)
        XCTAssertTrue(m.transition(to: .ringing))
        XCTAssertFalse(m.phase.allowsMedia, "microphone must stay closed while ringing")
        XCTAssertTrue(m.apply(serverStatus: .accepted))
        XCTAssertTrue(m.phase.allowsMedia)
        XCTAssertTrue(m.transition(to: .connecting))
        XCTAssertTrue(m.transition(to: .connected))
        XCTAssertTrue(m.transition(to: .ended))
        XCTAssertTrue(m.phase.isTerminal)
    }

    func testIncomingStartsRingingAndCanDecline() {
        var m = CallStateMachine(direction: .incoming)
        XCTAssertEqual(m.phase, .ringing)
        XCTAssertTrue(m.apply(serverStatus: .declined))
        XCTAssertEqual(m.phase, .declined)
    }

    func testCallerCancelWhileRinging() {
        var m = CallStateMachine(direction: .incoming)
        XCTAssertTrue(m.apply(serverStatus: .cancelled))
        XCTAssertEqual(m.phase, .cancelled)
    }

    func testTimeoutBecomesMissed() {
        var m = CallStateMachine(direction: .outgoing)
        m.transition(to: .ringing)
        XCTAssertTrue(m.apply(serverStatus: .missed))
        XCTAssertEqual(m.phase.label, "No answer")
    }

    func testTerminalStatesAreFinal() {
        var m = CallStateMachine(direction: .incoming)
        m.apply(serverStatus: .declined)
        XCTAssertFalse(m.apply(serverStatus: .accepted), "a late accepted event must not revive a declined call")
        XCTAssertFalse(m.transition(to: .connected))
        XCTAssertEqual(m.phase, .declined)
    }

    func testDuplicateEventsAreIgnored() {
        var m = CallStateMachine(direction: .incoming)
        XCTAssertTrue(m.apply(serverStatus: .accepted))
        XCTAssertFalse(m.apply(serverStatus: .accepted), "realtime + polling may deliver the same row twice")
    }

    func testServerConnectingDoesNotRewindLocalConnected() {
        var m = CallStateMachine(direction: .outgoing)
        m.transition(to: .ringing); m.apply(serverStatus: .accepted)
        m.transition(to: .connecting); m.transition(to: .connected)
        XCTAssertFalse(m.apply(serverStatus: .connecting))
        XCTAssertEqual(m.phase, .connected)
    }

    func testReconnectCycle() {
        var m = CallStateMachine(direction: .outgoing)
        m.transition(to: .ringing); m.apply(serverStatus: .accepted); m.transition(to: .connected)
        XCTAssertTrue(m.transition(to: .reconnecting))
        XCTAssertFalse(m.apply(serverStatus: .connected), "server 'connected' must not hide a local reconnect")
        XCTAssertTrue(m.transition(to: .connected))
    }

    func testCannotSkipRinging() {
        var m = CallStateMachine(direction: .outgoing)
        XCTAssertFalse(m.transition(to: .connected))
        XCTAssertFalse(m.transition(to: .accepted))
    }

    func testDurationFormatting() {
        XCTAssertEqual(CallDurationFormatter.string(0), "00:00")
        XCTAssertEqual(CallDurationFormatter.string(272), "04:32")
        XCTAssertEqual(CallDurationFormatter.string(3725), "1:02:05")
        XCTAssertEqual(CallDurationFormatter.string(-3), "00:00")
    }
}
