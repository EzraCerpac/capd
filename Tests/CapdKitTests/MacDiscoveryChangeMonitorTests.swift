import Foundation
import GRDB
import Testing

@testable import CapdKit

struct MacDiscoveryChangeMonitorTests {
    @Test func equalInodesOnDifferentDevicesReopenTheReader() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        try paths.createDirectories()
        let firstURL = root.appendingPathComponent("first.sqlite")
        let secondURL = root.appendingPathComponent("second.sqlite")
        let firstWriter = try DatabaseQueue(path: firstURL.path)
        let secondWriter = try DatabaseQueue(path: secondURL.path)
        for writer in [firstWriter, secondWriter] {
            try writer.write { try $0.execute(sql: "CREATE TABLE sample (value TEXT)") }
        }
        try FileManager.default.createSymbolicLink(
            at: paths.databaseURL, withDestinationURL: firstURL)
        var device: UInt64 = 11
        let monitor = MacDiscoveryChangeMonitor(paths: paths) { path in
            var attributes = try FileManager.default.attributesOfItem(atPath: path)
            attributes[.systemNumber] = NSNumber(value: device)
            attributes[.systemFileNumber] = NSNumber(value: 123)
            return attributes
        }
        let initial = try monitor.revision()
        #expect(try monitor.revision() == initial)
        try FileManager.default.removeItem(at: paths.databaseURL)
        try FileManager.default.createSymbolicLink(
            at: paths.databaseURL, withDestinationURL: secondURL)
        device = 22
        let retargeted = try monitor.revision()
        #expect(retargeted.fileNumber == initial.fileNumber)
        #expect(retargeted.dataVersion == initial.dataVersion)
        #expect(retargeted != initial)
        #expect(try monitor.revision() == retargeted)
        try secondWriter.write { try $0.execute(sql: "INSERT INTO sample VALUES ('New volume')") }
        #expect(try monitor.revision() != retargeted)
    }

    @Test(arguments: [false, true])
    func revisionTracksCommitsConfigurationAndDatabaseReplacement(throughSymlink: Bool) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capd-discovery-revision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        try paths.createDirectories()
        let databaseURL =
            throughSymlink ? root.appendingPathComponent("target.sqlite") : paths.databaseURL
        let writer = try DatabaseQueue(path: databaseURL.path)
        if throughSymlink {
            try FileManager.default.createSymbolicLink(
                at: paths.databaseURL, withDestinationURL: databaseURL)
        }
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
        try Data(contentsOf: replacementURL).write(to: databaseURL, options: .atomic)
        let replaced = try monitor.revision()
        #expect(replaced != committed)
        #expect(try monitor.revision() == replaced)
    }
}
