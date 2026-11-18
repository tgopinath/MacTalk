import Foundation
import Network
import Observation

/// Reachability via NWPathMonitor; drives reconnection after the network returns.
@MainActor @Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    /// Bumped whenever the path changes in a way that invalidates sockets (Wi-Fi → Ethernet, VPN…).
    private(set) var pathGeneration = 0
    var onChange: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private var lastInterfaces: [String] = []

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let interfaces = path.availableInterfaces.map(\.name)
            Task { @MainActor in self?.update(online: online, interfaces: interfaces) }
        }
        monitor.start(queue: DispatchQueue(label: "app.mactalk.network"))
    }

    private func update(online: Bool, interfaces: [String]) {
        let changed = online != isOnline || interfaces != lastInterfaces
        isOnline = online
        lastInterfaces = interfaces
        if changed { pathGeneration += 1; onChange?(online) }
    }
}
