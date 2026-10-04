import Foundation
import GRDB

/// Keeps one read-only connection because SQLite data versions are comparable only within a connection.
public final class MacDiscoveryChangeMonitor {
    public struct Revision: Equatable {
        let fileNumber: UInt64
        let dataVersion: Int
        let configuration: Data?
    }

    private let paths: StoragePaths
    private var reader: DatabaseQueue?
    private var fileNumber: UInt64?

    public init(paths: StoragePaths) { self.paths = paths }

    public func revision() throws -> Revision {
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.databaseURL.path)
        guard let currentFile = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw MacDiscoveryError.invalidIdentity
        }
        if reader == nil || fileNumber != currentFile {
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(5)
            reader = try DatabaseQueue(path: paths.databaseURL.path, configuration: configuration)
            fileNumber = currentFile
        }
        let version = try reader!.read { db in
            try Int.fetchOne(db, sql: "PRAGMA data_version")!
        }
        return Revision(
            fileNumber: currentFile, dataVersion: version,
            configuration: try MacSyncConfiguration.bytes(paths: paths))
    }
}
