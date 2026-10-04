import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdKit

struct MacDiscoveryAliasTests {
    @Test(arguments: [false, true])
    func snapshotsUseCanonicalIdentityWithoutChangingMappings(includeCanonicalRow: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let deviceID = UUID()
        let store = try Store(paths: paths, syncBinding: binding, deviceID: deviceID)
        let enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.invalid/v1/sync")!,
            binding: binding, deviceID: deviceID)
        try MacSyncConfiguration(enrollment: enrollment).install(paths: paths)
        let alias = UUID()
        var record = SharedCapture(
            source: CaptureSource(kind: .text, title: "Canonical capture", selection: "Synthetic"))
        record.revision = 7
        record.manualTags = ["canonical"]
        try store.dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO sync_visible (id, payload) VALUES (?, ?)",
                arguments: [record.id.uuidString, try JSONEncoder().encode(record)])
            try db.execute(
                sql: "INSERT INTO sync_aliases (id, canonical) VALUES (?, ?)",
                arguments: [alias.uuidString, record.id.uuidString])
            var capture = Capture(
                kind: .text, title: "Canonical capture", selection: "Synthetic", createdAt: Date())
            try capture.insert(db)
            try db.execute(
                sql: "INSERT INTO sync_capture_ids (local_id, global_id) VALUES (?, ?)",
                arguments: [capture.id, alias.uuidString])
            if includeCanonicalRow {
                var second = Capture(
                    kind: .text, title: "Canonical capture", selection: "Synthetic",
                    createdAt: Date())
                try second.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_capture_ids (local_id, global_id) VALUES (?, ?)",
                    arguments: [second.id, record.id.uuidString])
            }
        }
        let before = try store.dbPool.read {
            try String.fetchAll($0, sql: "SELECT global_id FROM sync_capture_ids ORDER BY local_id")
        }
        let snapshot = try MacDiscoverySnapshot.load(paths: paths, localLibraryID: UUID())
        #expect(snapshot.libraryID == binding.libraryID)
        #expect(snapshot.captures.map(\.id) == [record.id])
        #expect(snapshot.captures.first?.manualTags == ["canonical"])
        #expect(snapshot.captures.first?.revision == 7)
        #expect(try store.syncClient!.pendingOperations().isEmpty)
        #expect(
            try store.dbPool.read {
                try String.fetchAll(
                    $0, sql: "SELECT global_id FROM sync_capture_ids ORDER BY local_id")
            } == before)
    }
}
