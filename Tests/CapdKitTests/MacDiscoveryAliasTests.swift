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
        let expectedLocalID = try store.dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO sync_visible (id, payload) VALUES (?, ?)",
                arguments: [record.id.uuidString, try JSONEncoder().encode(record)])
            try db.execute(
                sql: "INSERT INTO sync_aliases (id, canonical) VALUES (?, ?)",
                arguments: [alias.uuidString, record.id.uuidString])
            var capture = Capture(
                kind: .text, title: "Stale alias title", selection: "Synthetic", createdAt: Date())
            try capture.insert(db)
            try db.execute(
                sql: "INSERT INTO sync_capture_ids (local_id, global_id) VALUES (?, ?)",
                arguments: [capture.id, alias.uuidString])
            if includeCanonicalRow {
                var second = Capture(
                    kind: .text, title: "Stale local title", selection: "Synthetic",
                    createdAt: Date())
                try second.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_capture_ids (local_id, global_id) VALUES (?, ?)",
                    arguments: [second.id, record.id.uuidString])
                return second.id
            }
            return capture.id
        }
        let before = try store.dbPool.read {
            try String.fetchAll($0, sql: "SELECT global_id FROM sync_capture_ids ORDER BY local_id")
        }
        let snapshot = try MacDiscoverySnapshot.load(paths: paths, localLibraryID: UUID())
        #expect(snapshot.libraryID == binding.libraryID)
        #expect(snapshot.captures.map(\.id) == [record.id])
        #expect(snapshot.captures.first?.manualTags == ["canonical"])
        #expect(snapshot.captures.first?.revision == 7)
        #expect(snapshot.captures.first?.title == "Canonical capture")
        #expect(snapshot.captures.first?.localID == expectedLocalID)
        #expect(try store.syncClient!.pendingOperations().isEmpty)
        #expect(
            try store.dbPool.read {
                try String.fetchAll(
                    $0, sql: "SELECT global_id FROM sync_capture_ids ORDER BY local_id")
            } == before)
    }

    @Test(arguments: [1000, 1001])
    func limitCountsCanonicalCapturesInsteadOfRetainedAliases(canonicalCount: Int) throws {
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
        let first = UUID()
        try store.dbPool.write { db in
            let alias = UUID()
            try db.execute(
                sql: "INSERT INTO sync_aliases (id, canonical) VALUES (?, ?)",
                arguments: [alias.uuidString, first.uuidString])
            var retained = Capture(kind: .text, title: "Retained alias", createdAt: Date())
            try retained.insert(db)
            try db.execute(
                sql: "INSERT INTO sync_capture_ids (local_id, global_id) VALUES (?, ?)",
                arguments: [retained.id, alias.uuidString])
            for index in 0..<canonicalCount {
                let record = SharedCapture(
                    id: index == 0 ? first : UUID(),
                    source: CaptureSource(kind: .text, title: "Canonical \(index)"))
                try db.execute(
                    sql: "INSERT INTO sync_visible (id, payload) VALUES (?, ?)",
                    arguments: [record.id.uuidString, try JSONEncoder().encode(record)])
                var capture = Capture(kind: .text, title: "Canonical \(index)", createdAt: Date())
                try capture.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_capture_ids (local_id, global_id) VALUES (?, ?)",
                    arguments: [capture.id, record.id.uuidString])
            }
        }
        if canonicalCount == 1000 {
            let snapshot = try MacDiscoverySnapshot.load(paths: paths, localLibraryID: UUID())
            #expect(snapshot.captures.count == 1000)
            #expect(snapshot.captures.first?.title == "Canonical 0")
        } else {
            #expect(throws: MacDiscoveryError.self) {
                try MacDiscoverySnapshot.load(paths: paths, localLibraryID: UUID())
            }
        }
    }

    @Test func syncedDerivedTextTitlesDoNotExposeSourceSelection() throws {
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
        let selection = "  Private source token " + String(repeating: "secret ", count: 20) + "  "
        let derived = String(selection.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let sources = [
            CaptureSource(kind: .text, title: derived, selection: selection),
            CaptureSource(kind: .text, title: "Explicit saved title", selection: selection),
            CaptureSource(kind: .link, title: derived, selection: selection),
        ]
        try store.dbPool.write { db in
            for source in sources {
                var record = SharedCapture(source: source)
                record.manualTags = ["manual"]
                record.revision = 9
                try db.execute(
                    sql: "INSERT INTO sync_visible (id, payload) VALUES (?, ?)",
                    arguments: [record.id.uuidString, try JSONEncoder().encode(record)])
                var capture = Capture(kind: .text, title: "Stale local title", createdAt: Date())
                try capture.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_capture_ids (local_id, global_id) VALUES (?, ?)",
                    arguments: [capture.id, record.id.uuidString])
            }
        }
        let before = try store.dbPool.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_visible ORDER BY id")
        }
        let snapshot = try MacDiscoverySnapshot.load(paths: paths, localLibraryID: UUID())
        #expect(snapshot.captures.map(\.title) == ["Saved text", "Explicit saved title", derived])
        #expect(snapshot.captures.allSatisfy { $0.manualTags == ["manual"] && $0.revision == 9 })
        #expect(try store.syncClient!.pendingOperations().isEmpty)
        #expect(
            try store.dbPool.read {
                try Data.fetchAll($0, sql: "SELECT payload FROM sync_visible ORDER BY id")
            } == before)
    }

    @Test(arguments: [true, false])
    func untitledLinksIndexOnlyTheHost(hasHost: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        let store = try Store(paths: paths)
        var capture = Capture(
            kind: .link,
            url: "https://example.invalid/private/path?q=private-token#private-fragment",
            host: hasHost ? "example.invalid" : nil, createdAt: Date())
        try store.dbPool.write { try capture.insert($0) }
        let snapshot = try MacDiscoverySnapshot.load(paths: paths, localLibraryID: UUID())
        #expect(snapshot.captures.first?.title == "example.invalid")
    }
}
