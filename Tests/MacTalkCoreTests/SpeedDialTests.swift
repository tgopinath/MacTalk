import XCTest
@testable import MacTalkCore

final class SpeedDialTests: XCTestCase {
    private func friends(_ names: [String]) -> [Friend] {
        names.map { Friend(id: UUID().uuidString, email: "\($0.lowercased())@example.com", displayName: $0, presenceStatus: .online, lastSeen: Date()) }
    }

    func testDefaultsToAlphabeticalOrder() {
        let list = friends(["Zoe", "alex", "Mia"])
        let dial = SpeedDial()
        XCTAssertEqual(dial.ordered(list).map(\.name), ["alex", "Mia", "Zoe"])
        XCTAssertEqual(dial.friend(forSlot: 1, in: list)?.name, "alex")
        XCTAssertEqual(dial.friend(forSlot: 3, in: list)?.name, "Zoe")
        XCTAssertNil(dial.friend(forSlot: 4, in: list))
    }

    func testSlotsOutsideOneToNineAreRejected() {
        let list = friends((1...12).map { "F\(String(format: "%02d", $0))" })
        let dial = SpeedDial()
        XCTAssertNil(dial.friend(forSlot: 0, in: list))
        XCTAssertNil(dial.friend(forSlot: 10, in: list))
        XCTAssertEqual(dial.slot(for: dial.ordered(list)[8].id, in: list), 9)
        XCTAssertNil(dial.slot(for: dial.ordered(list)[9].id, in: list), "only nine friends get a shortcut")
    }

    func testMovePinsOrder() {
        let list = friends(["Ann", "Ben", "Cat"])
        var dial = SpeedDial()
        dial.move(in: list, from: IndexSet(integer: 2), to: 0) // Cat to the top
        XCTAssertEqual(dial.ordered(list).map(\.name), ["Cat", "Ann", "Ben"])
        dial.move(in: list, from: IndexSet(integer: 0), to: 3) // Cat to the bottom
        XCTAssertEqual(dial.ordered(list).map(\.name), ["Ann", "Ben", "Cat"])
    }

    func testRemovedFriendsDropOutAndNewOnesAppend() {
        var list = friends(["Ann", "Ben", "Cat"])
        var dial = SpeedDial()
        dial.move(in: list, from: IndexSet(integer: 2), to: 0)
        list.removeAll { $0.name == "Ann" }
        list += friends(["Dan"])
        XCTAssertEqual(dial.ordered(list).map(\.name), ["Cat", "Ben", "Dan"])
    }
}
