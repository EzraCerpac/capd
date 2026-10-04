import Foundation
import GRDB
import Testing

@testable import CapdSync

@Suite("Explicit content snapshot imports")
struct ContentSnapshotImportTests {
    @Test func previewPreservesConflictsAndImportsCountAsLowerBoundWithHonestNewReceipts() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        var original = f.capture(id: f.duplicateID, hash: "duplicate", note: "Mac note")
        original.metadata = CaptureMetadata(
            updatedAt: f.date, reminderAt: f.date, sourceAppBundleID: "test.mac")
        original.generated = GeneratedContent(body: "Mac body", tags: ["Mac generated"])
        original.manualTags = ["Mac tag"]
        let operation = f.operation(original)
        let oldReceipt = try f.server.apply(operation)
        try f.server.apply(
            SyncOperation(
                deviceID: f.seedDevice, sequence: 2, captureID: original.id,
                baseRevision: 1, mutation: .recapture))
        let history = try f.history()
        let feed = try f.server.changes(after: 0, limit: 100).changes
        let feedBytes = try f.feedBytes()
        var duplicate = f.capture(id: f.phoneDuplicateID, hash: "duplicate", note: "Phone note")
        duplicate.seenCount = 7
        duplicate.rating = 1
        duplicate.createdMetadata(f.date.addingTimeInterval(0.0000001))
        duplicate.generated = GeneratedContent(
            body: "Phone body", ocrText: "Phone OCR", tags: ["Phone generated"])
        duplicate.manualTags = ["Phone tag"]
        duplicate.unknownFields = [
            "futurePhone": .object(["exact": .number(Decimal(string: "9007199254740993")!)])
        ]
        var unique = f.capture(id: f.uniqueID, hash: "unique", note: "Imported original note")
        unique.seenCount = 4
        unique.metadata = duplicate.metadata
        unique.noteConflicts = [
            NoteVariant(
                operationID: UUID(), value: "Original unresolved variant",
                unknownFields: ["future": .bool(true)])
        ]
        unique.revision = 99
        unique.noteRevision = 99
        let snapshot = f.snapshot([duplicate, unique])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(try f.history() == history)
        #expect(try f.tableExists("sync_content_snapshot_imports") == false)
        let match = try #require(preview.items.first { $0.source.id == duplicate.id })
        #expect(match.authority?.metadata == original.metadata)
        #expect(match.source.metadata == duplicate.metadata)
        #expect(match.differingFields.contains(.metadata))
        #expect(match.differingFields.contains(.seenCount))
        #expect(match.differingFields.contains(.note))
        #expect(match.differingFields.contains(.generated))
        #expect(match.proposedSeenCount == 7)
        #expect(!match.countIsExact)
        #expect(preview.items.allSatisfy { !$0.countIsExact })
        #expect(preview.feedRowsToExpire == feed.count)
        let receipt = try f.server.importContentSnapshot(snapshot, preview: preview)
        #expect(receipt.id != operation.id)
        #expect(receipt.items.allSatisfy { $0.id != operation.id })
        #expect(try f.history() == history)
        #expect(try f.server.apply(operation) == oldReceipt)
        #expect(try f.server.expiredContentSnapshotFeed(snapshot.snapshotID) == feed)
        #expect(try f.feedBytes(snapshot.snapshotID) == feedBytes)
        #expect(throws: SyncError.cursorExpired) {
            try f.server.changes(after: preview.authorityCursor, limit: 100)
        }
        let imported = try #require(try f.server.baseline().captures.first { $0.id == unique.id })
        #expect(imported.seenCount == 4)
        #expect(imported.createdAt == unique.createdAt)
        #expect(imported.metadata == unique.metadata)
        #expect(imported.note == unique.note)
        #expect(imported.noteOperationID != unique.noteOperationID)
        #expect(
            imported.noteConflicts.first?.operationID != unique.noteConflicts.first?.operationID)
        #expect(
            imported.noteConflicts.first?.unknownFields == unique.noteConflicts.first?.unknownFields
        )
        #expect(imported.noteRevision == receipt.authorityCursor)
        let merged = try #require(try f.server.baseline().captures.first { $0.id == original.id })
        #expect(merged.seenCount == 7)
        #expect(merged.createdAt == original.createdAt)
        #expect(merged.metadata == original.metadata)
        #expect(merged.generated == original.generated)
        #expect(merged.rating == original.rating)
        #expect(merged.manualTags == ["Mac tag", "Phone tag"])
        #expect(Set(merged.noteConflicts.compactMap(\.value)) == ["Mac note", "Phone note"])
        let retained = try #require(try f.server.retainedContentSnapshotImport(snapshot.snapshotID))
        #expect(retained.snapshot == snapshot)
        #expect(retained.preview == preview)
        #expect(retained.receipt == receipt)
        #expect(try f.server.importContentSnapshot(snapshot, preview: preview) == receipt)
        let reopened = try f.reopenServer()
        #expect(try reopened.importContentSnapshot(snapshot, preview: preview) == receipt)
        #expect(try f.history() == history)
        let repeatedContent = f.snapshot([duplicate], snapshotID: UUID())
        try reopened.importContentSnapshot(
            repeatedContent, preview: reopened.previewContentSnapshotImport(repeatedContent))
        #expect(try reopened.baseline().captures.first { $0.id == original.id }?.seenCount == 7)
        #expect(
            try reopened.baseline().captures.first { $0.id == original.id }?.noteConflicts.count
                == 2)
        var changed = duplicate
        changed.note = "Changed snapshot bytes"
        #expect(throws: ContentSnapshotImportError.snapshotIDReused) {
            try reopened.importContentSnapshot(
                f.snapshot([changed, unique], snapshotID: snapshot.snapshotID), preview: preview)
        }
    }

    @Test func expiredFeedRecoversConnectedClientsWithoutAcknowledgingPendingOverlays() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.duplicateID, hash: "duplicate", note: "Authority note")
        let seed = f.operation(capture)
        let seedReceipt = try f.server.apply(seed)
        let a = try f.client("a")
        let b = try f.client("b")
        try a.pull(from: f.transport(a.deviceID))
        try b.pull(from: f.transport(b.deviceID))
        let note = try a.enqueue(
            captureID: capture.id,
            mutation: .edit(CaptureEdit(note: NoteEdit("Offline connected-client note"))))
        let local = f.capture(id: UUID(), hash: "unrelated-local", note: "Local new capture")
        let create = try b.enqueue(captureID: local.id, mutation: .create(local))
        let aBytes = try f.outbox("a")
        let bBytes = try f.outbox("b")
        let before = try f.history()
        let feed = try f.server.changes(after: 0, limit: 100).changes
        var phone = f.capture(
            id: f.phoneDuplicateID, hash: "duplicate", note: "Phone content snapshot note")
        phone.seenCount = 5
        phone.revision = 71
        phone.noteRevision = 71
        let snapshot = f.snapshot([phone])
        let imported = try f.server.importContentSnapshot(
            snapshot, preview: f.server.previewContentSnapshotImport(snapshot))
        #expect(try f.history() == before)
        #expect(try f.server.baseline().deviceSequences[snapshot.sourceDeviceID] == nil)
        #expect(try f.server.apply(seed) == seedReceipt)
        #expect(try f.server.expiredContentSnapshotFeed(snapshot.snapshotID) == feed)
        try a.pull(from: f.transport(a.deviceID))
        try b.pull(from: f.transport(b.deviceID))
        #expect(try a.cursor() == imported.authorityCursor)
        #expect(try b.cursor() == imported.authorityCursor)
        #expect(try a.pendingOperations() == [note])
        #expect(try b.pendingOperations() == [create])
        #expect(try f.outbox("a") == aBytes)
        #expect(try f.outbox("b") == bBytes)
        #expect(try a.captures().first?.note == "Offline connected-client note")
        #expect(try a.captures().first?.seenCount == 5)
        #expect(try b.captures().contains { $0.id == local.id && $0.note == "Local new capture" })
        let newReceipt = try #require(try a.push(to: f.transport(a.deviceID)).first)
        #expect(newReceipt.operationID == note.id)
        #expect(newReceipt.outcome == .noteConflict)
        #expect(try a.pendingOperations().isEmpty)
        #expect(try f.server.baseline().deviceSequences[a.deviceID] == 1)
        try b.push(to: f.transport(b.deviceID))
        #expect(try b.pendingOperations().isEmpty)
        #expect(try f.server.baseline().deviceSequences[b.deviceID] == 1)
    }

    @Test func stalePreviewAndIdentityCollisionNeverChangeAuthority() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.duplicateID, hash: "duplicate", note: "Original")
        try f.server.apply(f.operation(capture))
        let snapshot = f.snapshot([f.capture(id: f.uniqueID, hash: "new")])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        try f.server.apply(
            SyncOperation(
                deviceID: f.seedDevice, sequence: 2, captureID: capture.id,
                baseRevision: 1,
                mutation: .edit(CaptureEdit(note: NoteEdit("Changed after preview")))))
        let baseline = try f.server.baseline()
        let history = try f.history()
        #expect(throws: ContentSnapshotImportError.stalePreview) {
            try f.server.importContentSnapshot(snapshot, preview: preview)
        }
        #expect(try f.server.baseline().captures == baseline.captures)
        #expect(try f.history() == history)
        #expect(try f.tableExists("sync_content_snapshot_imports") == false)
        let collision = f.snapshot([f.capture(id: capture.id, hash: "different")])
        #expect(throws: ContentSnapshotImportError.identityCollision) {
            try f.server.previewContentSnapshotImport(collision)
        }
        let currentPreview = try f.server.previewContentSnapshotImport(snapshot)
        try f.server.expireFeed(through: baseline.cursor)
        #expect(throws: ContentSnapshotImportError.stalePreview) {
            try f.server.importContentSnapshot(snapshot, preview: currentPreview)
        }
    }

    @Test func sqlFailureRollsBackAllRowsAliasesLedgerAndFeedExpiration() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.duplicateID, hash: "duplicate", note: "Keep original")
        try f.server.apply(f.operation(capture))
        var duplicate = f.capture(
            id: f.phoneDuplicateID, hash: "duplicate", note: "Imported conflict")
        duplicate.seenCount = 8
        let unique = f.capture(id: f.uniqueID, hash: "trigger-failure")
        let snapshot = f.snapshot([duplicate, unique])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        let before = try f.logicalState()
        try f.database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_snapshot_insert BEFORE INSERT ON sync_records
                    WHEN NEW.id = '\(unique.id.uuidString)'
                    BEGIN SELECT RAISE(ABORT, 'synthetic import failure'); END;
                    """)
        }
        #expect(throws: (any Error).self) {
            try f.server.importContentSnapshot(snapshot, preview: preview)
        }
        #expect(try f.logicalState() == before)
        #expect(try f.tableExists("sync_content_snapshot_imports") == false)
        #expect(try f.tableExists("sync_content_snapshot_expired_feed") == false)
        try f.database.write { try $0.execute(sql: "DROP TRIGGER fail_snapshot_insert") }
        try f.server.importContentSnapshot(snapshot, preview: preview)
        #expect(try f.server.baseline().captures.count == 2)
    }

    @Test func tombstonesAndRepeatedSnapshotContentNeverBecomeRecaptures() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.duplicateID, hash: "deleted", note: "Deleted authority note")
        try f.server.apply(f.operation(capture))
        try f.server.apply(
            SyncOperation(
                deviceID: f.seedDevice, sequence: 2, captureID: capture.id, baseRevision: 1,
                mutation: .delete))
        var phone = f.capture(id: f.phoneDuplicateID, hash: "deleted", note: "Live phone original")
        phone.seenCount = 12
        let snapshot = f.snapshot([phone])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(preview.items.first?.disposition == .preserveTombstone)
        #expect(preview.items.first?.differingFields.contains(.deleted) == true)
        #expect(preview.items.first?.proposedSeenCount == 1)
        try f.server.importContentSnapshot(snapshot, preview: preview)
        let result = try #require(try f.server.baseline().captures.first)
        #expect(result.deleted)
        #expect(result.seenCount == 1)
        #expect(result.note == capture.note)
        #expect(
            try f.server.retainedContentSnapshotImport(snapshot.snapshotID)?.snapshot.captures.first
                == phone)
        var deadUnique = f.capture(id: f.uniqueID, hash: "phone-tombstone")
        deadUnique.deleted = true
        deadUnique.seenCount = 3
        let deadSnapshot = f.snapshot([deadUnique], snapshotID: UUID())
        try f.server.importContentSnapshot(
            deadSnapshot, preview: f.server.previewContentSnapshotImport(deadSnapshot))
        #expect(try f.server.baseline().captures.first { $0.id == deadUnique.id }?.deleted == true)
        #expect(try f.server.baseline().captures.first { $0.id == deadUnique.id }?.seenCount == 3)
    }

    @Test func duplicateRowsWithinSnapshotUseMaximumAndRetainBothOriginals() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        var first = f.capture(
            id: f.phoneDuplicateID, hash: "same-phone-content", note: "Phone first note")
        first.seenCount = 4
        var second = f.capture(
            id: f.uniqueID, hash: "same-phone-content", note: "Phone second note")
        second.seenCount = 9
        second.metadata = CaptureMetadata(sourceAppBundleID: "test.second")
        let snapshot = f.snapshot([second, first])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(preview.items.map(\.proposedSeenCount) == [4, 9])
        try f.server.importContentSnapshot(snapshot, preview: preview)
        let records = try f.server.baseline().captures
        #expect(records.count == 1)
        #expect(records.first?.seenCount == 9)
        #expect(
            Set(records.first!.noteConflicts.compactMap(\.value)) == [
                "Phone first note", "Phone second note",
            ])
        #expect(
            try f.server.retainedContentSnapshotImport(snapshot.snapshotID)?.snapshot == snapshot)
    }

    @Test func malformedBindingInvalidCountsAndMissingAssetsFailBeforeImport() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.uniqueID, hash: "unique")
        #expect(throws: SyncBindingError.mismatch) {
            try f.server.previewContentSnapshotImport(
                ContentSnapshotImport(
                    snapshotID: UUID(),
                    targetBinding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()),
                    sourceDeviceID: UUID(), captures: [capture]))
        }
        #expect(throws: ContentSnapshotImportError.invalidSnapshot) {
            try f.server.previewContentSnapshotImport(f.snapshot([]))
        }
        #expect(throws: ContentSnapshotImportError.invalidSnapshot) {
            try f.server.previewContentSnapshotImport(f.snapshot([capture, capture]))
        }
        var invalid = capture
        invalid.seenCount = 0
        #expect(throws: ContentSnapshotImportError.invalidSnapshot) {
            try f.server.previewContentSnapshotImport(f.snapshot([invalid]))
        }
        let bytes = Data("Synthetic imported image".utf8)
        let blob = BlobReference(data: bytes)
        let image = SharedCapture(
            source: CaptureSource(kind: .image, contentHash: blob.digest, blob: blob),
            createdAt: f.date)
        let snapshot = f.snapshot([capture, image])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(throws: SyncError.blobMissing) {
            try f.server.importContentSnapshot(snapshot, preview: preview)
        }
        #expect(try f.server.baseline().captures.isEmpty)
        #expect(try f.tableExists("sync_content_snapshot_imports") == false)
        try f.server.upload(blob, offset: 0, chunk: bytes, final: true)
        try f.server.importContentSnapshot(snapshot, preview: preview)
        #expect(try f.server.download(blob) == bytes)
    }
}

extension SharedCapture {
    fileprivate mutating func createdMetadata(_ date: Date) {
        metadata = CaptureMetadata(
            updatedAt: date, lastSeenAt: date.addingTimeInterval(1),
            reminderAt: date.addingTimeInterval(2),
            sourceAppBundleID: "test.phone", unknownFields: ["futureMetadata": .string("retained")])
    }
}

private struct SnapshotAuthorizer: SyncAuthorizer {
    let binding: SyncLibraryBinding
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        guard let device = UUID(uuidString: bearerCredential) else { return nil }
        return SyncPrincipal(
            serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: device)
    }
}

private struct SnapshotFixture {
    let root: URL
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let seedDevice = UUID()
    let sourceDevice = UUID()
    let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let phoneDuplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let uniqueID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    let date = Date(timeIntervalSinceReferenceDate: 123_456_789.12345679)
    let server: SyncServer
    let database: DatabaseQueue
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-content-snapshot-\(UUID())")
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        database = try DatabaseQueue(path: root.appendingPathComponent("authority.sqlite").path)
    }
    func capture(id: UUID, hash: String, note: String? = nil) -> SharedCapture {
        SharedCapture(
            id: id,
            source: CaptureSource(
                kind: .text, contentHash: hash, title: "Original \(hash)",
                selection: "Original \(hash)"),
            createdAt: date, note: note)
    }
    func operation(_ capture: SharedCapture) -> SyncOperation {
        SyncOperation(
            deviceID: seedDevice, sequence: 1, captureID: capture.id, baseRevision: 0,
            mutation: .create(capture))
    }
    func snapshot(_ captures: [SharedCapture], snapshotID: UUID = UUID()) -> ContentSnapshotImport {
        ContentSnapshotImport(
            snapshotID: snapshotID, targetBinding: binding, sourceDeviceID: sourceDevice,
            captures: captures)
    }
    func client(_ name: String) throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("\(name).sqlite"),
            blobDirectory: root.appendingPathComponent("\(name)-blobs"), binding: binding)
    }
    func transport(_ device: UUID) -> SyncHTTPTransport {
        let handler = SyncHTTPHandler(
            serviceID: binding.serviceID, authorizer: SnapshotAuthorizer(binding: binding),
            server: { _ in server })
        return SyncHTTPTransport(
            binding: binding, deviceID: device, credential: { device.uuidString },
            execute: { handler.handle($0) })
    }
    func reopenServer() throws -> SyncServer {
        try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
    }
    func tableExists(_ name: String) throws -> Bool {
        try database.read { try $0.tableExists(name) }
    }
    func history() throws -> [String: [Row]] {
        try database.read { db in
            [
                "receipts": try Row.fetchAll(db, sql: "SELECT * FROM sync_receipts ORDER BY id"),
                "devices": try Row.fetchAll(db, sql: "SELECT * FROM sync_devices ORDER BY id"),
            ]
        }
    }
    func logicalState() throws -> [String: [Row]] {
        try database.read { db in
            try Dictionary(
                uniqueKeysWithValues: [
                    "sync_records", "sync_aliases", "sync_meta", "sync_feed", "sync_receipts",
                    "sync_devices",
                ].map {
                    ($0, try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY 1"))
                })
        }
    }
    func feedBytes(_ snapshotID: UUID? = nil) throws -> [Data] {
        try database.read { db in
            if let snapshotID {
                return try Data.fetchAll(
                    db,
                    sql:
                        "SELECT payload FROM sync_content_snapshot_expired_feed WHERE import_id=? ORDER BY cursor",
                    arguments: [snapshotID.uuidString])
            }
            return try Data.fetchAll(db, sql: "SELECT payload FROM sync_feed ORDER BY cursor")
        }
    }

    func outbox(_ name: String) throws -> [Data] {
        let db = try DatabaseQueue(path: root.appendingPathComponent("\(name).sqlite").path)
        return try db.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
