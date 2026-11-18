import Foundation
import MacTalkCore

/// Two live streams per signed-in user carry everything MacTalk needs:
/// - `u/{uid}`: friends, outgoing invitations, blocks and incoming call rings
/// - `inbox/{emailKey}`: invitations sent to this user's email
/// Both are protected by database.rules.json (only the owner can read them).
@MainActor
final class RealtimeHub {
    var onUserNode: (([String: Any]?) -> Void)?
    var onInbox: (([String: Any]?) -> Void)?
    var onRings: (([CallID: RingEntry]) -> Void)?

    private let backend: Backend
    private var tasks: [Task<Void, Never>] = []
    private(set) var userID: UserID?

    init(backend: Backend) { self.backend = backend }

    func start(userID: UserID) {
        self.userID = userID
        subscribe()
    }

    func stop() {
        userID = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// Drops and rebuilds the streams (after wake or a network change).
    func restart() {
        guard userID != nil else { return }
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        subscribe()
    }

    private func subscribe() {
        guard let uid = userID, let key = backend.myEmailKey else { return }
        let userStream = backend.db.observe("u/\(uid)")
        let inboxStream = backend.db.observe("inbox/\(key)")
        tasks = [
            Task { [weak self] in
                for await tree in userStream {
                    let node = tree.value as? [String: Any]
                    self?.onUserNode?(node)
                    self?.onRings?(Self.rings(from: node?["rings"]))
                }
            },
            Task { [weak self] in
                for await tree in inboxStream { self?.onInbox?(tree.value as? [String: Any]) }
            },
        ]
    }

    static func rings(from value: Any?) -> [CallID: RingEntry] {
        var result: [CallID: RingEntry] = [:]
        for (id, entry) in (value as? [String: Any]) ?? [:] {
            if let ring: RingEntry = JSONTree.decode(entry) { result[id] = ring }
        }
        return result
    }
}
