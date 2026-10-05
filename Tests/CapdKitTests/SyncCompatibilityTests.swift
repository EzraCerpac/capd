import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdKit

@Suite("Synthetic sync compatibility")
struct SyncCompatibilityTests {
    @Test(
        "Identity backfill keeps local keys, content fingerprints, schema and FTS; reopen is stable"
    )
    func backfill() throws {
        try withSyncFixture { paths in
            let store = try Store(paths: paths)
            let source = Capture(
                kind: .text, title: "Synthetic platypus", note: "fixture annotation",
                tags: "manual", tagsVersion: Capture.pinnedTagsVersion,
                contentHash: "fixture fingerprint",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            let capture = try store.upsertCapture(source).capture
            let second = try store.upsertCapture(
                Capture(
                    kind: .text, title: "Second fixture",
                    createdAt: source.createdAt)
            ).capture
            let ids = try SyncPrototype.backfillIdentities(in: store.dbPool)
            #expect(ids.count == 2)
            #expect(Set(ids.values).count == 2)
            #expect(try SyncPrototype.backfillIdentities(in: store.dbPool) == ids)
            let reopened = try Store(paths: paths)
            #expect(try SyncPrototype.backfillIdentities(in: reopened.dbPool) == ids)
            let loaded = try SearchService(store: reopened).capture(id: capture.id!)
            #expect(loaded == capture)
            #expect(try SearchService(store: reopened).capture(id: second.id!) == second)
            try reopened.reader.read { db in
                let applied = try Migrations.migrator.appliedMigrations(db)
                let journal = try String.fetchOne(db, sql: "PRAGMA journal_mode")
                let columns = try db.columns(in: Schema.capturesFTS).map(\.name)
                #expect(applied == ["001", "002", "003", "004", "005", "006"])
                #expect(journal == "wal")
                #expect(columns == Schema.ranking.map(\.column))
            }
            let snapshot = SyncPrototype.snapshot(capture, globalID: ids[capture.id!]!)
            #expect(snapshot.id != ids[second.id!])
            #expect(snapshot.source.contentHash == capture.contentHash)
            #expect(snapshot.manualTags == ["manual"])
            #expect(snapshot.generated.tags.isEmpty)
            #expect(
                try SearchService(store: reopened).search("platypus").first?.capture.id
                    == capture.id)
        }
    }

    @Test(
        "Transactional projection preserves FTS source rows, local enrichment state and URL fallback"
    )
    func searchProjection() throws {
        try withSyncFixture { paths in
            let store = try Store(paths: paths)
            _ = try SyncPrototype.backfillIdentities(in: store.dbPool)
            let blobs = try BlobStore(directory: paths.assetsDirectory)
            let client = try SyncClient(
                writer: store.dbPool, blobs: blobs, deviceID: UUID(),
                project: { db, record in try SyncPrototype.project(db, record: record) })
            let server = try SyncServer(
                databaseURL: paths.root.appendingPathComponent("server.sqlite"),
                blobDirectory: paths.root.appendingPathComponent("server-assets"))
            let search = SearchService(store: store)
            var record = SharedCapture(
                source: CaptureSource(
                    kind: .link, contentHash: "synthetic link",
                    url: "https://example.invalid/unique-substring-123", host: "example.invalid",
                    title: "Synthetic kestrel"),
                note: "annotation narwhal")
            record.generated = GeneratedContent(
                body: "body pangolin", ocrText: "ocr axolotl", tags: ["generated"])
            try client.enqueue(captureID: record.id, mutation: .create(record))
            let local = try search.search("kestrel").first!.capture
            for term in ["narwhal", "pangolin", "axolotl", "generated", "unique-substring-123"] {
                #expect(try search.search(term).first?.capture.id == local.id)
            }
            try store.dbPool.write { db in
                try db.execute(
                    sql:
                        "UPDATE captures SET enrichment_state = 'fetching', attempt_count = 2 WHERE id = ?",
                    arguments: [local.id])
            }
            try client.push(to: server)
            try client.enqueue(
                captureID: record.id,
                mutation: .edit(
                    CaptureEdit(note: NoteEdit("annotation okapi"), addTags: ["manualtag"])))
            #expect(try search.search("narwhal").isEmpty)
            #expect(try search.search("okapi").first?.capture.id == local.id)
            #expect(try search.search("manualtag").first?.capture.id == local.id)
            let updated = try search.capture(id: local.id!)!
            #expect(updated.enrichmentState == .fetching)
            #expect(updated.attemptCount == 2)
            #expect(updated.tagsVersion == Capture.pinnedTagsVersion)
            try client.push(to: server)
            try client.pull(from: server)
            #expect(try client.pendingOperations().isEmpty)
            #expect(try search.totalCaptureCount() == 1)
            try client.enqueue(captureID: record.id, mutation: .delete)
            #expect(try search.search("kestrel").isEmpty)
            #expect(try search.search("unique-substring-123").isEmpty)
            try client.push(to: server)
            try client.enqueue(captureID: record.id, mutation: .restore)
            #expect(try search.search("kestrel").first?.capture.id == local.id)
            try client.push(to: server)
            #expect(try search.totalCaptureCount() == 1)
        }
    }

    @Test("Legacy local recapture and annotation semantics stay intact")
    func localOnlySemantics() throws {
        try withSyncFixture { paths in
            let store = try Store(paths: paths)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let first = try store.upsertCapture(
                Capture(
                    kind: .text, title: "Synthetic source",
                    note: "first", contentHash: "same", createdAt: now)
            ).capture
            let second = try store.upsertCapture(
                Capture(
                    kind: .text, note: "second",
                    contentHash: "same", createdAt: now.addingTimeInterval(10))
            ).capture
            #expect(first.id == second.id)
            #expect(second.seenCount == 2)
            #expect(second.note == "first")
            #expect(try store.updateNote(id: first.id!, note: nil).note == nil)
            try store.reader.read { db in
                let meta = try db.tableExists("sync_meta")
                let ids = try db.tableExists("sync_capture_ids")
                #expect(!meta)
                #expect(!ids)
            }
        }
    }
}

private func withSyncFixture(_ body: (StoragePaths) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-sync-compat-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try body(StoragePaths(root: root))
}
