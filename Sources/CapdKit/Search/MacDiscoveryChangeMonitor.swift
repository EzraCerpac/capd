import Foundation
import GRDB

/// Keeps one read-only connection because SQLite data versions are comparable only within a connection.
public final class MacDiscoveryChangeMonitor {
    public struct Revision: Equatable {
        let systemNumber: UInt64
        let fileNumber: UInt64
        let dataVersion: Int
        let configuration: Data?
    }

    private let paths: StoragePaths
    private let attributes: (String) throws -> [FileAttributeKey: Any]
    private var reader: DatabaseQueue?
    private var fileNumber: UInt64?
    private var systemNumber: UInt64?

    public convenience init(paths: StoragePaths) {
        self.init(paths: paths, attributes: FileManager.default.attributesOfItem(atPath:))
    }

    init(paths: StoragePaths, attributes: @escaping (String) throws -> [FileAttributeKey: Any]) {
        self.paths = paths
        self.attributes = attributes
    }

    public func revision() throws -> Revision {
        let attributes = try attributes(
            paths.databaseURL.resolvingSymlinksInPath().path)
        guard let currentSystem = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            let currentFile = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            throw MacDiscoveryError.invalidIdentity
        }
        if reader == nil || fileNumber != currentFile || systemNumber != currentSystem {
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(5)
            reader = try DatabaseQueue(path: paths.databaseURL.path, configuration: configuration)
            fileNumber = currentFile
            systemNumber = currentSystem
        }
        let version = try reader!.read { db in
            try Int.fetchOne(db, sql: "PRAGMA data_version")!
        }
        return Revision(
            systemNumber: currentSystem, fileNumber: currentFile, dataVersion: version,
            configuration: try MacSyncConfiguration.bytes(paths: paths))
    }
}
