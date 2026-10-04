import Foundation
import GRDB
import Testing

@testable import CapdSync

@Suite("Lossless metadata and atomic enqueue")
struct MetadataAndTransactionTests {
    @Test func freshBoundBlobOwnershipMarkerPermitsPreparationButActualBlobStillRefuses() throws {
        let f = try MetadataFixture()
        defer { f.clean() }
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let blobs = try BlobStore(
            directory: f.root.appendingPathComponent("bound-blobs"), binding: binding)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: blobs.directory.path) == [
                "library-owner"
            ])
        let client = try SyncClient(writer: f.writer, blobs: blobs, binding: binding)
        #expect(client.binding == binding)
        #expect(try client.pendingOperations().isEmpty)
        #expect(
            try SyncClient(writer: f.writer, blobs: blobs, binding: binding).deviceID
                == client.deviceID)
        let used = try MetadataFixture()
        defer { used.clean() }
        let populated = try BlobStore(
            directory: used.root.appendingPathComponent("bound-blobs"), binding: binding)
        _ = try populated.put(Data("Synthetic preexisting asset".utf8))
        #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
            try SyncClient(writer: used.writer, blobs: populated, binding: binding)
        }
        #expect(try used.writer.read { try !$0.tableExists("sync_binding") })
    }

    @Test func legacyEncodingAndUnknownDescriptiveFieldsRoundTripWithoutRewritingOutbox() throws {
        let f = try MetadataFixture()
        defer { f.clean() }
        var capture = f.capture()
        let legacy = try SyncDatabase.encode(capture)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("metadata"))
        #expect(try SyncDatabase.encode(SyncDatabase.decode(SharedCapture.self, legacy)) == legacy)
        var object = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        object["futureRecord"] = ["nested": [true, NSNull(), "kept"]]
        var source = object["source"] as! [String: Any]
        source["futureSource"] = ["precision": 9_007_199_254_740_993 as Int64]
        object["source"] = source
        var generated = object["generated"] as! [String: Any]
        generated["futureGenerated"] = "kept"
        object["generated"] = generated
        capture = try SyncDatabase.decode(
            SharedCapture.self, JSONSerialization.data(withJSONObject: object))
        capture.metadata = CaptureMetadata(
            updatedAt: f.date, lastSeenAt: f.date.addingTimeInterval(1.0000001),
            reminderAt: f.date.addingTimeInterval(2.0000002),
            sourceAppBundleID: "test.original-app",
            unknownFields: [
                "futureMetadata": .object(["value": .number(Decimal(string: "9007199254740993")!)])
            ])
        let client = try f.client()
        let op = try client.enqueue(captureID: capture.id, mutation: .create(capture))
        let before = try f.payloads()
        #expect(try SyncDatabase.encode(client.pendingOperations()[0]) == before[0])
        #expect(try f.client().pendingOperations() == [op])
        #expect(try f.payloads() == before)
        let redecoded = try SyncDatabase.decode(SharedCapture.self, SyncDatabase.encode(capture))
        #expect(redecoded == capture)
        #expect(
            redecoded.metadata?.updatedAt?.timeIntervalSinceReferenceDate
                == f.date.timeIntervalSinceReferenceDate)
        #expect(
            redecoded.source.unknownFields["futureSource"]
                == .object(["precision": .number(Decimal(string: "9007199254740993")!)]))
    }

    @Test func reminderAbsenceNullSetClearAndIndependentEditsPreserveOriginalProvenance() throws {
        let f = try MetadataFixture()
        defer { f.clean() }
        let client = try f.client()
        let server = try f.server()
        var capture = f.capture()
        capture.metadata = CaptureMetadata(
            updatedAt: f.date, lastSeenAt: f.date,
            reminderAt: f.date.addingTimeInterval(100), sourceAppBundleID: "test.original-app",
            unknownFields: ["opaque": .string("retained")])
        capture.generated = GeneratedContent(body: "Body", ocrText: "OCR", tags: ["generated"])
        capture.generated.unknownFields = ["future": .bool(true)]
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        try client.push(to: server)
        for encoded in ["{}", #"{"reminder":null}"#] {
            let patch = try SyncDatabase.decode(CaptureMetadataPatch.self, Data(encoded.utf8))
            #expect(patch.reminder == nil)
            try client.enqueue(captureID: capture.id, mutation: .edit(CaptureEdit(metadata: patch)))
            try client.push(to: server)
            #expect(try client.captures()[0].metadata?.reminderAt == capture.metadata?.reminderAt)
        }
        let next = f.date.addingTimeInterval(0.1234567)
        try client.enqueue(
            captureID: capture.id,
            mutation: .edit(
                CaptureEdit(
                    metadata: CaptureMetadataPatch(updatedAt: next, reminder: .clear),
                    sourceContent: SourceContentPatch(
                        title: "Filled title", selection: "Ignored replacement"),
                    generatedPatch: GeneratedContentPatch(body: .clear))))
        try client.push(to: server)
        let accepted = try client.captures()[0]
        #expect(accepted.createdAt == capture.createdAt)
        #expect(accepted.metadata?.updatedAt == next)
        #expect(accepted.metadata?.lastSeenAt == f.date)
        #expect(accepted.metadata?.sourceAppBundleID == "test.original-app")
        #expect(accepted.metadata?.reminderAt == nil)
        #expect(accepted.metadata?.unknownFields == capture.metadata?.unknownFields)
        #expect(accepted.source.title == "Filled title")
        #expect(accepted.source.selection == capture.source.selection)
        #expect(accepted.source.contentHash == capture.source.contentHash)
        #expect(accepted.generated.body == nil)
        #expect(accepted.generated.ocrText == "OCR")
        #expect(accepted.generated.tags == ["generated"])
        #expect(accepted.generated.unknownFields == capture.generated.unknownFields)
        try client.enqueue(
            captureID: capture.id,
            mutation: .edit(
                CaptureEdit(
                    metadata: CaptureMetadataPatch(reminder: .set(next)),
                    sourceContent: SourceContentPatch(title: "Must not overwrite"),
                    generatedPatch: GeneratedContentPatch(ocrText: .set("Updated OCR"), tags: []))))
        try client.push(to: server)
        #expect(try client.captures()[0].metadata?.reminderAt == next)
        #expect(try client.captures()[0].source.title == "Filled title")
        #expect(try client.captures()[0].generated.ocrText == "Updated OCR")
        #expect(try client.captures()[0].generated.tags.isEmpty)
    }

    @Test func unsupportedMutationOrEditDoesNotSilentlyBecomeAnAcceptedNoOp() throws {
        #expect(throws: (any Error).self) {
            try SyncDatabase.decode(CaptureMutation.self, Data(#"{"futureMutation":{}}"#.utf8))
        }
        let f = try MetadataFixture()
        defer { f.clean() }
        let client = try f.client()
        let capture = f.capture()
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        let original = try f.payloads()
        let unknown = try SyncDatabase.decode(
            CaptureEdit.self,
            Data(#"{"addTags":[],"removeTags":[],"futureEdit":{"critical":true}}"#.utf8))
        #expect(unknown.unknownFields["futureEdit"] != nil)
        let unknownNote = try SyncDatabase.decode(
            CaptureEdit.self,
            Data(
                #"{"addTags":[],"removeTags":[],"note":{"value":"change","resolving":[],"futureSemantics":true}}"#
                    .utf8))
        #expect(unknownNote.note?.unknownFields["futureSemantics"] == .bool(true))
        for edit in [
            unknown, unknownNote,
            CaptureEdit(
                metadata: CaptureMetadataPatch(unknownFields: [
                    "sourceAppBundleID": .string("spoof")
                ])),
            CaptureEdit(
                sourceContent: SourceContentPatch(unknownFields: ["url": .string("changed")])),
            CaptureEdit(
                generated: GeneratedContent(), generatedPatch: GeneratedContentPatch(body: .clear)),
        ] {
            #expect(throws: SyncError.invalidOperation) {
                try client.enqueue(captureID: capture.id, mutation: .edit(edit))
            }
        }
        #expect(try f.payloads() == original)
        var collision = capture
        collision.unknownFields["createdAt"] = .number(1)
        #expect(throws: (any Error).self) { try SyncDatabase.encode(collision) }
    }

    @Test func sourceRowMappingOutboxAndSequenceCommitOrRollbackTogether() throws {
        let f = try MetadataFixture()
        defer { f.clean() }
        let client = try f.client()
        let capture = f.capture()
        try f.writer.write { db in
            try db.execute(sql: "CREATE TABLE local_source (id TEXT PRIMARY KEY, title TEXT)")
        }
        #expect(throws: InjectedFailure.self) {
            try f.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO local_source VALUES (?, ?)",
                    arguments: [capture.id.uuidString, "Mac capture"])
                try client.enqueue(in: db, captureID: capture.id, mutation: .create(capture))
                throw InjectedFailure.rollback
            }
        }
        #expect(
            try f.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM local_source") }
                == 0)
        #expect(try client.pendingOperations().isEmpty)
        #expect(try client.captures().isEmpty)
        let op = try f.writer.write { db in
            try db.execute(
                sql: "INSERT INTO local_source VALUES (?, ?)",
                arguments: [capture.id.uuidString, "Mac capture"])
            return try client.enqueue(in: db, captureID: capture.id, mutation: .create(capture))
        }
        #expect(op.sequence == 1)
        #expect(try client.pendingOperations() == [op])
        #expect(
            try f.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM local_source") }
                == 1)
        #expect(try f.client().pendingOperations() == [op])
    }

    @Test func transactionEnqueueRejectsOtherWritersEvenForSameFileAndRequiresTransaction() throws {
        let f = try MetadataFixture()
        defer { f.clean() }
        let client = try f.client()
        let capture = f.capture()
        #expect(throws: SyncTransactionError.requiresTransaction) {
            try f.writer.writeWithoutTransaction {
                try client.enqueue(in: $0, captureID: capture.id, mutation: .create(capture))
            }
        }
        let other = try DatabaseQueue(path: f.database.path)
        #expect(throws: SyncTransactionError.wrongWriter) {
            try other.write {
                try client.enqueue(in: $0, captureID: capture.id, mutation: .create(capture))
            }
        }
        #expect(try client.pendingOperations().isEmpty)
    }

    @Test func projectionExceptionRollsBackOuterSourceWriteAndRecursiveProjectionIsRejected() throws
    {
        let f = try MetadataFixture()
        defer { f.clean() }
        try f.writer.write { try $0.execute(sql: "CREATE TABLE local_source (id TEXT)") }
        let client = try f.client(project: { _, _ in throw InjectedFailure.projection })
        let capture = f.capture()
        #expect(throws: InjectedFailure.projection) {
            try f.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO local_source VALUES (?)", arguments: [capture.id.uuidString])
                try client.enqueue(in: db, captureID: capture.id, mutation: .create(capture))
            }
        }
        #expect(
            try f.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM local_source") }
                == 0)
        #expect(try client.pendingOperations().isEmpty)
        let box = ClientBox()
        let recursive = try f.client(project: { _, record in
            try box.client!.enqueue(captureID: record.id, mutation: .recapture)
        })
        box.client = recursive
        defer { box.client = nil }
        #expect(throws: SyncTransactionError.projectionFeedback) {
            try recursive.enqueue(captureID: capture.id, mutation: .create(capture))
        }
        #expect(try recursive.pendingOperations().isEmpty)
        let good = try f.client()
        #expect(try good.enqueue(captureID: capture.id, mutation: .create(capture)).sequence == 1)
    }
    @Test func preparationFailureRollsBackBindingSchemaDeviceAndBaselineTogether() throws {
        let f = try MetadataFixture()
        defer { f.clean() }
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let device = UUID()
        let capture = f.capture()
        let writerIdentity = f.writer.writeWithoutTransaction { ObjectIdentifier($0) }
        #expect(throws: InjectedFailure.projection) {
            try SyncClient(
                writer: f.writer,
                blobs: BlobStore(directory: f.root.appendingPathComponent("blobs")),
                deviceID: device, binding: binding,
                prepareProjection: { db in
                    #expect(ObjectIdentifier(db) == writerIdentity)
                    #expect(db.isInsideTransaction)
                    try SyncDatabase.save(db, capture)
                    try db.execute(sql: "CREATE TABLE import_marker (id TEXT)")
                    throw InjectedFailure.projection
                })
        }
        #expect(try f.writer.read { try !$0.tableExists("sync_binding") })
        #expect(try f.writer.read { try !$0.tableExists("sync_meta") })
        #expect(try f.writer.read { try !$0.tableExists("sync_records") })
        #expect(try f.writer.read { try !$0.tableExists("import_marker") })
        let client = try SyncClient(
            writer: f.writer, blobs: BlobStore(directory: f.root.appendingPathComponent("blobs")),
            deviceID: device, binding: binding,
            prepareProjection: { db in
                try SyncDatabase.save(db, capture)
            })
        #expect(client.deviceID == device)
        #expect(client.binding == binding)
        #expect(try f.writer.read { try SyncDatabase.record($0, id: capture.id) } == capture)
    }

    @Test func preparationHookCannotBypassUsedUnboundGuardOrReassignBinding() throws {
        let f = try MetadataFixture()
        defer { f.clean() }
        let client = try f.client()
        let capture = f.capture()
        let op = try client.enqueue(captureID: capture.id, mutation: .create(capture))
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
            try SyncClient(
                writer: f.writer,
                blobs: BlobStore(directory: f.root.appendingPathComponent("blobs")),
                binding: binding,
                prepareProjection: { _ in Issue.record("Guard must reject before hook") })
        }
        #expect(try client.pendingOperations() == [op])
        let fresh = try MetadataFixture()
        defer { fresh.clean() }
        #expect(throws: SyncBindingError.mismatch) {
            try SyncClient(
                writer: fresh.writer,
                blobs: BlobStore(directory: fresh.root.appendingPathComponent("blobs")),
                binding: binding,
                prepareProjection: { db in try db.execute(sql: "DELETE FROM sync_binding") })
        }
        #expect(try fresh.writer.read { try !$0.tableExists("sync_binding") })
    }

}

private enum InjectedFailure: Error { case rollback, projection }
private final class ClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SyncClient?
    var client: SyncClient? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
private struct MetadataFixture {
    let root: URL
    let database: URL
    let writer: DatabaseQueue
    let date = Date(timeIntervalSinceReferenceDate: 123_456_789.12345679)
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = root.appendingPathComponent("client.sqlite")
        writer = try DatabaseQueue(path: database.path)
    }
    func client(project: @escaping SyncClient.Projection = { _, _ in }) throws -> SyncClient {
        try SyncClient(
            writer: writer, blobs: BlobStore(directory: root.appendingPathComponent("blobs")),
            project: project)
    }
    func server() throws -> SyncServer {
        try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-blobs"))
    }
    func capture() -> SharedCapture {
        SharedCapture(
            source: CaptureSource(
                kind: .text, contentHash: "fixed-identity", selection: "Original selection"),
            createdAt: date)
    }
    func payloads() throws -> [Data] {
        try writer.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
