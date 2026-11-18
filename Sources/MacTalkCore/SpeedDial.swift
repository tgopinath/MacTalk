import Foundation

/// Speed-dial slots 1…9 (⌃1 … ⌃9). The user orders friends in Manage Friends; friends
/// they haven't placed yet fill the remaining slots alphabetically.
public struct SpeedDial: Sendable, Equatable {
    public static let maxSlots = 9
    public private(set) var order: [UUID]

    public init(order: [UUID] = []) { self.order = order }

    /// Friends in speed-dial order, keeping only current friends and appending new ones.
    public func ordered(_ friends: [Friend]) -> [Friend] {
        let byID = Dictionary(uniqueKeysWithValues: friends.map { ($0.id, $0) })
        var result = order.compactMap { byID[$0] }
        let placed = Set(result.map(\.id))
        result += friends.filter { !placed.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    /// The friend bound to slot 1…9, if any.
    public func friend(forSlot slot: Int, in friends: [Friend]) -> Friend? {
        guard (1...Self.maxSlots).contains(slot) else { return nil }
        let list = ordered(friends)
        return slot <= list.count ? list[slot - 1] : nil
    }

    public func slot(for friendID: UUID, in friends: [Friend]) -> Int? {
        guard let index = ordered(friends).firstIndex(where: { $0.id == friendID }), index < Self.maxSlots else { return nil }
        return index + 1
    }

    /// Moves friends (SwiftUI `onMove` semantics) and pins the resulting order.
    public mutating func move(in friends: [Friend], from source: IndexSet, to destination: Int) {
        var list = ordered(friends).map(\.id)
        let moving = source.sorted().map { list[$0] }
        for index in source.sorted(by: >) { list.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        list.insert(contentsOf: moving, at: max(0, min(insertAt, list.count)))
        order = list
    }
}
