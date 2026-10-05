import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdKit

struct StoreSyncImportHandoffValidationTests {
    @Test(arguments: [
        "negative-note-revision", "future-note-revision", "zero-revision", "note-conflicts",
        "zero-seen-count", "mismatched-identity",
    ])
    func malformedHistoricalBaselineDoesNotInstallEnrollment(kind: String) throws {
        let fixture = try ImportHandoffFixture(seenCount: kind == "zero-seen-count" ? 0 : 3)
        defer { fixture.clean() }
        var records = try fixture.records()
        switch kind {
        case "negative-note-revision": records[1].noteRevision = -1
        case "future-note-revision": records[1].noteRevision = 2
        case "zero-revision": records[1].revision = 0
        case "note-conflicts":
            records[1].noteConflicts = [
                NoteVariant(operationID: records[1].noteOperationID, value: records[1].note),
                NoteVariant(operationID: UUID(), value: "Conflicting note"),
            ]
        case "mismatched-identity": records[1] = records[0]
        default: break
        }
        let before = try fixture.databaseState()
        #expect(throws: SyncError.invalidOperation) {
            let handoff = try StoreSyncImportHandoff(
                store: fixture.store, transport: fixture.transport(records: records))
            _ = try Store(paths: fixture.paths, syncBinding: fixture.binding, imported: handoff)
        }
        #expect(try fixture.databaseState() == before)
        #expect(try fixture.store.reader.read { try StoreSync.binding(in: $0) } == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.paths.assetsDirectory.appendingPathComponent("sync/library-owner")
                    .path))
    }

    @Test(arguments: [Int64(0), Int64(1)])
    func validHistoricalNoteRevisionsAndRecordOrderArePreserved(noteRevision: Int64) throws {
        let fixture = try ImportHandoffFixture(seenCount: Int.max)
        defer { fixture.clean() }
        var records = try fixture.records()
        for index in records.indices {
            records[index].noteRevision = noteRevision
            records[index].unknownFields = ["futureHistoricalField": .string("retained")]
        }
        let handoff = try StoreSyncImportHandoff(
            store: fixture.store, transport: fixture.transport(records: Array(records.reversed())))
        let imported = try Store(
            paths: fixture.paths, syncBinding: fixture.binding, imported: handoff)
        let client = try #require(imported.syncClient)
        #expect(try client.captures().sorted { $0.id.uuidString < $1.id.uuidString } == records)
        #expect(try client.cursor() == 1)
        #expect(try client.pendingOperations().isEmpty)
        #expect(try imported.reader.read { try StoreSync.binding(in: $0) } == fixture.binding)
        #expect(try imported.reader.read { try Capture.fetchCount($0) } == 2)
    }
}

private struct ImportHandoffFixture {
    let root: URL
    let paths: StoragePaths
    let binding: SyncLibraryBinding
    let deviceID: UUID
    let store: Store

    init(seenCount: Int) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-import-handoff-validation-\(UUID())", isDirectory: true)
        paths = StoragePaths(root: root.appendingPathComponent("mac", isDirectory: true))
        binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        deviceID = UUID()
        store = try Store(paths: paths)
        let service = CaptureService(store: store)
        for index in 1...2 {
            let capture = try service.ingest(
                CaptureRequest(
                    text: "Historical capture \(index)", note: "Historical note \(index)",
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
            ).capture
            try store.dbPool.write { db in
                try StoreSync.prepareIDs(db)
                try db.execute(
                    sql: "INSERT INTO sync_capture_ids VALUES (?,?)",
                    arguments: [
                        capture.id,
                        UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!.uuidString,
                    ])
                try db.execute(
                    sql: "UPDATE captures SET seen_count=? WHERE id=?",
                    arguments: [seenCount, capture.id])
            }
        }
    }

    func records() throws -> [SharedCapture] {
        try store.reader.read { db in
            try Capture.order(Capture.CodingKeys.id).fetchAll(db).map { capture in
                let id = try #require(capture.id)
                let value = try #require(
                    try String.fetchOne(
                        db, sql: "SELECT global_id FROM sync_capture_ids WHERE local_id=?",
                        arguments: [id]))
                var record = StoreSync.snapshot(capture, id: UUID(uuidString: value)!)
                record.revision = 1
                record.noteRevision = 1
                return record
            }
        }
    }

    func transport(records: [SharedCapture]) -> ImportHandoffTransport {
        ImportHandoffTransport(
            binding: binding, deviceID: deviceID,
            snapshot: Baseline(cursor: 1, captures: records, deviceSequences: [:]))
    }

    func databaseState() throws -> [String: [Row]] {
        try store.reader.read { db in
            let tables = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            return try Dictionary(
                uniqueKeysWithValues: tables.map { table in
                    (table, try Row.fetchAll(db, sql: "SELECT * FROM \(table)"))
                })
        }
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct ImportHandoffTransport: BoundSyncTransport {
    let binding: SyncLibraryBinding
    let deviceID: UUID
    let snapshot: Baseline

    func baseline() throws -> Baseline { snapshot }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        throw SyncError.invalidOperation
    }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        throw SyncError.invalidOperation
    }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        throw SyncError.invalidOperation
    }
    func download(_ blob: BlobReference) throws -> Data { throw SyncError.blobMissing }
}
