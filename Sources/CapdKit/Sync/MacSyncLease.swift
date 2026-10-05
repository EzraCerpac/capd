import Darwin
import Foundation

final class MacSyncLease: Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func acquire(paths: StoragePaths) throws -> MacSyncLease? {
        let file = paths.root.appendingPathComponent("sync-runtime.lock")
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MacSyncError.invalidConfiguration }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw MacSyncError.invalidConfiguration
        }
        return MacSyncLease(descriptor: descriptor)
    }

    static func wait(paths: StoragePaths) async throws -> MacSyncLease {
        let deadline = ContinuousClock.now.advanced(by: .seconds(35))
        while true {
            try Task.checkCancellation()
            if let lease = try acquire(paths: paths) { return lease }
            guard ContinuousClock.now < deadline else { throw MacSyncError.busy }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
