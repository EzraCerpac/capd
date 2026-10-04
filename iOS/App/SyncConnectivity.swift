import Foundation
import Network

final class SyncConnectivity {
    private let monitor = NWPathMonitor()
    init(changed: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in changed(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "capd.sync-connectivity"))
    }
    deinit { monitor.cancel() }
}
