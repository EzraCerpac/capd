import CapdSync
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import CapdKit

@Suite("Synthetic initial Mac import")
struct MigrationPreparationTests {
    @Test(
        "Mac snapshot imports as a bound baseline, preserves sidecar metadata, then accepts sequence one"
    )
    func initialImport() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/capd-mac-migration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root.appendingPathComponent("mac"))
        let store = try Store(paths: paths)
        try mark(paths.root)
        let imagePath = "nested/image.png"
        let imageURL = paths.assetURL(forRelativePath: imagePath)
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("synthetic image bytes".utf8)
        try bytes.write(to: imageURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try store.upsertCapture(
            Capture(
                id: 42, kind: .image, title: "Synthetic kestrel", note: "Keep the annotation",
                body: "Body pangolin", ocrText: "OCR axolotl", assetPath: imagePath,
                sourceAppBundleID: "example.synthetic", tags: "manual tag", tagsVersion: -1,
                rating: 5,
                contentHash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                reminderAt: now.addingTimeInterval(100),
                createdAt: now, lastSeenAt: now.addingTimeInterval(20), seenCount: 7)
        ).capture
        let generated = try store.upsertCapture(
            Capture(
                id: 81, kind: .text, title: "Generated tags", selection: "Generated source",
                tags: "generated", tagsVersion: 2, contentHash: "synthetic-text", createdAt: now)
        ).capture
        try run(["backfill", paths.root.path, "--database", "capd.sqlite"])
        let identities = try store.reader.read { db in
            try Dictionary(
                uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT * FROM sync_capture_ids").map {
                    ($0["local_id"] as Int64, UUID(uuidString: $0["global_id"] as String)!)
                })
        }
        let archive = root.appendingPathComponent("archive")
        try run([
            "backup", paths.root.path, "--destination", archive.path, "--database", "capd.sqlite",
        ])
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let authorityRoot = root.appendingPathComponent("authority")
        let authorityURL = authorityRoot.appendingPathComponent("server.sqlite")
        let server = try SyncServer(
            databaseURL: authorityURL,
            blobDirectory: authorityRoot.appendingPathComponent("assets"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        try mark(authorityRoot)
        let importID = UUID()
        let arguments = [
            "import-initial-mac", archive.path, "--destination", authorityRoot.path,
            "--library-id", binding.libraryID.uuidString, "--service-id",
            binding.serviceID.uuidString,
            "--import-id", importID.uuidString,
        ]
        try run(arguments)
        try run(arguments)
        let baseline = try server.baseline()
        #expect(baseline.cursor == 1)
        #expect(baseline.deviceSequences.isEmpty)
        #expect(baseline.captures.count == 2)
        #expect(throws: SyncError.cursorExpired) { try server.changes(after: 0) }
        let imported = try #require(baseline.captures.first { $0.id == identities[42] })
        #expect(imported.seenCount == 7)
        #expect(imported.rating == 5)
        #expect(imported.createdAt == now)
        #expect(imported.manualTags == ["manual", "tag"])
        #expect(imported.generated.body == original.body)
        #expect(imported.generated.ocrText == original.ocrText)
        #expect(try server.download(#require(imported.source.blob)) == bytes)
        #expect(
            baseline.captures.first { $0.id == identities[81] }?.generated.tags == ["generated"])
        #expect(try SearchService(store: store).capture(id: 42) == original)
        #expect(try SearchService(store: store).capture(id: 81) == generated)
        #expect(try SearchService(store: store).search("kestrel").first?.capture.id == 42)
        let authorityDB = try DatabaseQueue(path: authorityURL.path)
        try authorityDB.read { db in
            let payload = try #require(
                try Data.fetchOne(
                    db, sql: "SELECT payload FROM sync_imported_legacy WHERE local_id=42"))
            let sidecar = try #require(
                JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let row = try #require(sidecar["legacyRow"] as? [String: Any])
            #expect(row["source_app_bundle_id"] as? String == original.sourceAppBundleID)
            #expect(row["asset_path"] as? String == imagePath)
            #expect(row["reminder_at"] != nil)
            #expect(row["last_seen_at"] != nil)
        }
        let deviceID = UUID()
        let transport = ImportBoundTransport(
            server: server, binding: binding, deviceID: deviceID)
        let handoff = try StoreSyncImportHandoff(store: store, transport: transport)
        #expect(throws: SyncError.wrongDevice) {
            try Store(paths: paths, syncBinding: binding, imported: handoff, deviceID: UUID())
        }
        _ = try store.updateNote(
            id: 42, note: "Changed after handoff", now: now.addingTimeInterval(90))
        #expect(throws: SyncError.invalidOperation) {
            try Store(paths: paths, syncBinding: binding, imported: handoff)
        }
        try store.dbPool.write { db in try original.update(db) }
        // An asset changed after verification cannot become a different bound blob.
        try Data("altered synthetic bytes".utf8).write(to: imageURL)
        #expect(throws: SyncError.invalidOperation) {
            try Store(paths: paths, syncBinding: binding, imported: handoff)
        }
        try bytes.write(to: imageURL)
        try FileManager.default.removeItem(at: imageURL)
        #expect(throws: (any Error).self) {
            try Store(paths: paths, syncBinding: binding, imported: handoff)
        }
        try bytes.write(to: imageURL)
        // Force failure after image staging and before the seeded baseline can commit.
        try store.dbPool.write { db in
            try db.execute(
                sql: "CREATE TABLE sync_records (id TEXT PRIMARY KEY,payload BLOB NOT NULL)")
            try db.execute(
                sql:
                    "CREATE TRIGGER abort_seed BEFORE INSERT ON sync_records BEGIN SELECT RAISE(ABORT,'synthetic seed failure'); END"
            )
        }
        #expect(throws: (any Error).self) {
            try Store(paths: paths, syncBinding: binding, imported: handoff)
        }
        try store.reader.read { db throws -> Void in
            #expect(try StoreSync.binding(in: db) == nil)
            #expect(try !db.tableExists("sync_meta"))
            #expect(try Capture.fetchOne(db, key: 42) == original)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_records") == 0)
        }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: paths.assetsDirectory.appendingPathComponent("sync").path) == [
                    "library-owner"
                ])
        try store.dbPool.write { db in
            try db.execute(sql: "DROP TRIGGER abort_seed")
            try db.execute(sql: "DROP TABLE sync_records")
        }
        let attached = try Store(paths: paths, syncBinding: binding, imported: handoff)
        let client = try #require(attached.syncClient)
        #expect(client.deviceID == deviceID)
        #expect(try client.captures().count == 2)
        #expect(try client.pendingOperations().isEmpty)
        #expect(try SearchService(store: attached).capture(id: 42) == original)
        #expect(try SearchService(store: attached).capture(id: 81) == generated)
        #expect(try client.blobs.read(#require(imported.source.blob)) == bytes)
        #expect(throws: SyncBindingError.mismatch) {
            _ = try store.updateNote(id: 42, note: "Stale writer")
        }
        _ = try attached.updateNote(id: 42, note: "Edited", now: now.addingTimeInterval(200))
        let edit = try #require(try client.pendingOperations().first)
        #expect(edit.sequence == 1)
        #expect(edit.baseRevision == 1)
        #expect(try client.push(to: transport).first?.outcome == .accepted)
        #expect(try server.changes(after: 1).changes.first?.cursor == 2)
        #expect(try server.baseline().captures.first { $0.id == imported.id }?.seenCount == 7)
        let reopened = try SyncServer(
            databaseURL: authorityURL,
            blobDirectory: authorityRoot.appendingPathComponent("assets"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        #expect(try reopened.baseline().captures.count == 2)
        try run(arguments)
        #expect(try reopened.baseline().cursor == 2)
        let restored = root.appendingPathComponent("restored")
        try run(["restore", archive.path, "--destination", restored.path])
        let restoredStore = try Store(paths: StoragePaths(root: restored))
        #expect(try SearchService(store: restoredStore).capture(id: 42) == original)
        #expect(try SearchService(store: restoredStore).search("kestrel").first?.capture.id == 42)
    }

    private func mark(_ root: URL) throws {
        try Data("synthetic-capd-library-v1\n".utf8).write(
            to: root.appendingPathComponent(".capd-synthetic-fixture"))
    }

    private func run(_ arguments: [String]) throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments =
            [repo.appendingPathComponent("Scripts/synthetic_library_migration.py").path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "SyntheticMigration", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: bytes, as: UTF8.self)])
        }
    }
}

private struct ImportBoundTransport: BoundSyncTransport {
    let server: SyncServer
    let binding: SyncLibraryBinding
    let deviceID: UUID
    func apply(_ operation: SyncOperation) throws -> SyncReceipt { try server.apply(operation) }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try server.changes(after: cursor, limit: limit)
    }
    func baseline() throws -> Baseline { try server.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try server.download(blob) }
}
