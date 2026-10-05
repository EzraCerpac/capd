import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdKit

@Suite("Native capture identity compatibility")
struct NativeCaptureIdentityTests {
    @Test func legacyUpgradePreservesRowsIdentityAndFTS() throws {
        let fixture = NativeIdentityFixture()
        defer { fixture.clean() }
        let paths = fixture.paths
        try paths.createDirectories()
        let legacy = DatabaseMigrator.legacyCaptureIdentity
        let before: [Row]
        let identities: [Row]
        let triggers: [Row]
        let url = URL(string: "https://example.invalid/legacy")!
        let hash = CaptureIdentity.contentHash(for: url)
        do {
            let database = try DatabasePool(path: paths.databaseURL.path)
            try legacy.migrate(database)
            try database.write { db in
                var capture = Capture(
                    kind: .text, title: "Legacy kestrel", note: "Retained note",
                    selection: url.absoluteString, tags: "retained", contentHash: hash,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000))
                try capture.insert(db)
                try db.execute(
                    sql: """
                        CREATE TABLE sync_capture_ids (
                            local_id INTEGER PRIMARY KEY, global_id TEXT NOT NULL UNIQUE);
                        INSERT INTO sync_capture_ids VALUES (?, ?)
                        """, arguments: [capture.id, UUID().uuidString])
            }
            (before, identities, triggers) = try database.read { db in
                (
                    try Row.fetchAll(db, sql: "SELECT * FROM captures ORDER BY id"),
                    try Row.fetchAll(db, sql: "SELECT * FROM sync_capture_ids ORDER BY local_id"),
                    try Row.fetchAll(
                        db,
                        sql:
                            "SELECT name, sql FROM sqlite_master WHERE type='trigger' ORDER BY name"
                    )
                )
            }
            try database.close()
        }
        let upgraded = try Store(paths: paths)
        try upgraded.reader.read { db in
            #expect(try Row.fetchAll(db, sql: "SELECT * FROM captures ORDER BY id") == before)
            #expect(
                try Row.fetchAll(db, sql: "SELECT * FROM sync_capture_ids ORDER BY local_id")
                    == identities)
            #expect(
                try Row.fetchAll(
                    db,
                    sql: "SELECT name, sql FROM sqlite_master WHERE type='trigger' ORDER BY name")
                    == triggers)
            #expect(
                try Migrations.migrator.appliedMigrations(db) == [
                    "001", "002", "003", "004", "005", "006",
                ])
            #expect(try legacy.hasBeenSuperseded(db))
            let index = try #require(
                db.indexes(on: Schema.captures).first { $0.name == "captures_on_content_hash" })
            #expect(index.columns == ["kind", "content_hash"])
            #expect(index.isUnique)
        }
        let search = SearchService(store: upgraded)
        #expect(try search.search("kestrel").count == 1)
        #expect(try search.capture(url: url) == nil)
        let link = try CaptureService(store: upgraded).ingest(
            CaptureRequest(
                url: url.absoluteString, title: "New link", fetchBody: false,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_001))
        ).capture
        #expect(link.kind == .link)
        #expect(link.id != before.first?["id"] as Int64?)
        #expect(link.contentHash == hash)
        #expect(try search.capture(url: url)?.id == link.id)
        #expect(try search.totalCaptureCount() == 2)
        #expect(throws: DatabaseError.self) {
            try upgraded.dbPool.write { db in
                var duplicate = Capture(kind: .link, contentHash: hash, createdAt: Date())
                try duplicate.insert(db)
            }
        }
        let reopened = try Store(paths: paths)
        #expect(try SearchService(store: reopened).capture(url: url) == link)
        #expect(try SearchService(store: reopened).search("kestrel").count == 1)
        #expect(
            try reopened.reader.read { try Migrations.migrator.appliedMigrations($0) }.count == 6)
    }

    @Test func concurrentWritersDeduplicateWithinKind() async throws {
        let fixture = NativeIdentityFixture()
        defer { fixture.clean() }
        let first = try Store(paths: fixture.paths)
        let second = try Store(paths: fixture.paths)
        let url = "https://example.invalid/concurrent"
        let text = CaptureRequest(text: url, title: "Text kestrel")
        let link = CaptureRequest(url: url, title: "Link kestrel", fetchBody: false)
        let results = try await withThrowingTaskGroup(of: Capture.self) { group in
            for (store, request) in [(first, text), (second, link), (first, link), (second, text)] {
                group.addTask { try CaptureService(store: store).ingest(request).capture }
            }
            var captures: [Capture] = []
            for try await capture in group { captures.append(capture) }
            return captures
        }
        #expect(Set(results.compactMap(\.id)).count == 2)
        #expect(Set(results.map(\.kind)) == [.link, .text])
        let rows = try await first.reader.read { try Capture.fetchAll($0) }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.seenCount == 2 })
        #expect(Set(rows.compactMap(\.contentHash)).count == 1)
        #expect(try SearchService(store: first).capture(url: URL(string: url)!)?.kind == .link)
        #expect(try SearchService(store: first).search("kestrel").count == 2)
    }

    @Test(arguments: [CaptureSource.Kind.text, .link], [false, true])
    func unseenRemoteCrossKindHashProjectsInBothOrders(
        remoteKind: CaptureSource.Kind, pushBeforePull: Bool
    ) throws {
        let fixture = NativeIdentityFixture()
        defer { fixture.clean() }
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let server = try SyncServer(
            databaseURL: fixture.root.appendingPathComponent("authority.sqlite"),
            blobDirectory: fixture.root.appendingPathComponent("authority-assets"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        let url = URL(string: "https://example.invalid/shared")!
        let hash = CaptureIdentity.contentHash(for: url)
        #expect(hash == CaptureFingerprint.contentHash(for: Data(url.absoluteString.utf8)))
        let remote = SharedCapture(
            source: CaptureSource(
                kind: remoteKind, contentHash: hash,
                url: remoteKind == .link ? url.absoluteString : nil,
                title: "Remote kestrel", selection: remoteKind == .text ? url.absoluteString : nil),
            note: "Remote note")
        try server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: remote.id,
                baseRevision: 0, mutation: .create(remote)))
        let store = try Store(paths: fixture.paths, syncBinding: binding)
        let client = try #require(store.syncClient)
        let transport = NativeIdentityTransport(
            server: server, binding: binding, deviceID: client.deviceID)
        let request =
            remoteKind == .text
            ? CaptureRequest(url: url.absoluteString, title: "Offline link", fetchBody: false)
            : CaptureRequest(text: url.absoluteString, title: "Offline text")
        let local = try CaptureService(store: store).ingest(request).capture
        let pending = try client.pendingOperations()
        let localID = try #require(pending.first?.captureID)
        #expect(localID != remote.id)
        if pushBeforePull { #expect(try client.push(to: transport).first?.outcome == .accepted) }
        try client.pull(from: transport)
        let search = SearchService(store: store)
        #expect(try search.totalCaptureCount() == 2)
        #expect(try search.capture(id: local.id!)?.kind == local.kind)
        let visible = try client.captures()
        #expect(Set(visible.map(\.id)) == [localID, remote.id])
        #expect(Set(visible.compactMap { $0.source.contentHash }) == [hash])
        #expect(Set(visible.map { $0.source.kind }) == [.link, .text])
        if !pushBeforePull {
            #expect(try client.pendingOperations() == pending)
            #expect(try client.push(to: transport).first?.outcome == .accepted)
        }
        let recapture = SharedCapture(source: remote.source, note: remote.note)
        let receipt = try server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: recapture.id,
                baseRevision: 0, mutation: .create(recapture)))
        #expect(receipt.outcome == .accepted)
        #expect(receipt.capture?.id == remote.id)
        try client.pull(from: transport)
        #expect(try search.totalCaptureCount() == 2)
        #expect(try client.captures().first { $0.id == remote.id }?.seenCount == 2)
        #expect(try client.pendingOperations().isEmpty)
        let linkID = try #require(try client.captures().first { $0.source.kind == .link }?.id)
        let projectedLinkID = try store.reader.read {
            try Int64.fetchOne(
                $0, sql: "SELECT local_id FROM sync_capture_ids WHERE global_id=?",
                arguments: [linkID.uuidString])
        }
        #expect(try search.capture(url: url)?.id == projectedLinkID)
        #expect(try server.baseline().captures.count == 2)
        let reopened = try Store(paths: fixture.paths, syncBinding: binding)
        #expect(try SearchService(store: reopened).totalCaptureCount() == 2)
        #expect(try SearchService(store: reopened).capture(id: local.id!)?.kind == local.kind)
        #expect(try SearchService(store: reopened).capture(url: url)?.id == projectedLinkID)
    }
}

extension DatabaseMigrator {
    fileprivate static var legacyCaptureIdentity: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("001", migrate: Migrations.createCaptures)
        migrator.registerMigration("002", migrate: Migrations.addRetagRequest)
        migrator.registerMigration("003", migrate: Migrations.addRetagProgress)
        migrator.registerMigration("004", migrate: Migrations.addCaptureRating)
        migrator.registerMigration("005", migrate: Migrations.addCaptureReminder)
        return migrator
    }
}

private struct NativeIdentityFixture {
    let root = URL(
        fileURLWithPath: "/private/tmp/capd-native-identity-\(UUID())", isDirectory: true)
    var paths: StoragePaths { StoragePaths(root: root.appendingPathComponent("mac")) }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct NativeIdentityTransport: BoundSyncTransport {
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
