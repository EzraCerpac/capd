import Foundation
import GRDB
import Testing

@testable import CapdKit

struct MacDiscoveryChangeMonitorTests {
    @Test func revisionTracksCommitsConfigurationAndDatabaseReplacement() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capd-discovery-revision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        try paths.createDirectories()
        let writer = try DatabaseQueue(path: paths.databaseURL.path)
        try writer.write { try $0.execute(sql: "CREATE TABLE sample (value TEXT)") }
        let monitor = MacDiscoveryChangeMonitor(paths: paths)
        let initial = try monitor.revision()
        #expect(try monitor.revision() == initial)
        try writer.write { try $0.execute(sql: "INSERT INTO sample VALUES ('Changed')") }
        let committed = try monitor.revision()
        #expect(committed != initial)
        #expect(try monitor.revision() == committed)
        try Data("{}".utf8).write(to: MacSyncConfiguration.url(paths: paths))
        let configured = try monitor.revision()
        #expect(configured != committed)
        #expect(try monitor.revision() == configured)
        try FileManager.default.removeItem(at: MacSyncConfiguration.url(paths: paths))
        #expect(try monitor.revision() == committed)
        try writer.close()
        let replacementURL = root.appendingPathComponent("replacement.sqlite")
        let replacement = try DatabaseQueue(path: replacementURL.path)
        try replacement.write { try $0.execute(sql: "CREATE TABLE replacement (value TEXT)") }
        try replacement.close()
        try Data(contentsOf: replacementURL).write(to: paths.databaseURL, options: .atomic)
        let replaced = try monitor.revision()
        #expect(replaced != committed)
        #expect(try monitor.revision() == replaced)
    }
}
