import Foundation
import GRDB
import Testing

@testable import CapdMobile
@testable import CapdSync

@Suite(.timeLimit(.minutes(1)))
struct MobileResponseBudgetTests {
    @Test func individuallyFramableEditCannotQueueAnOversizedMergedReply() throws {
        let fixture = try ResponseBudgetFixture()
        defer { fixture.clean() }
        let capture = try CaptureInput.make(
            text: String(repeating: "t", count: 10 * 1_048_576), isLink: false)
        try fixture.store.save(capture)
        let before = try fixture.state()
        let note = String(repeating: "n", count: 7 * 1_048_576)
        let edit = SyncOperation(
            deviceID: fixture.store.deviceID, sequence: 2, captureID: capture.id,
            baseRevision: 0, mutation: .edit(CaptureEdit(note: NoteEdit(note))))
        let encoder = JSONEncoder()
        let requestFits =
            try encoder.encode(fixture.envelope(edit)).count <= SyncHTTPHandler.maximumBodyBytes
        #expect(requestFits)
        var prospective = try #require(try fixture.records().first)
        prospective.note = note
        let replyIsOversized =
            try encoder.encode(
                SyncHTTPReply(
                    version: 1,
                    principal: fixture.principal,
                    result: .receipt(
                        SyncReceipt(operationID: edit.id, outcome: .accepted, capture: prospective)),
                    metadataContractVersion: 1, generatedProcessingContractVersion: 1,
                    extractionQualityContractVersion: 1)
            ).count > SyncHTTPHandler.maximumBodyBytes
        #expect(replyIsOversized)
        #expect(throws: CaptureValidationError.tooLarge) {
            try fixture.store.update(id: capture.id, note: note, tags: [])
        }
        let unchanged = try fixture.state() == before
        #expect(unchanged)
        let reopened = try MobileStore(url: fixture.url)
        let noteUnchanged = try reopened.capture(id: capture.id)?.note == ""
        #expect(noteUnchanged)
        try reopened.update(id: capture.id, note: "Safe annotation", tags: ["manual"])
        #expect(try reopened.pending().map(\.sequence) == [1, 2])
        try reopened.push(to: fixture.server)
        #expect(try reopened.pending().isEmpty)
        #expect(try reopened.capture(id: capture.id)?.note == "Safe annotation")
    }

    @Test func knownConflictRetentionCannotQueueAnOversizedReply() throws {
        let fixture = try ResponseBudgetFixture()
        defer { fixture.clean() }
        var record = SharedCapture(
            source: CaptureSource(kind: .text, selection: "Known conflict source"),
            note: String(repeating: "a", count: 4 * 1_048_576))
        let firstDevice = UUID()
        _ = try fixture.server.apply(
            SyncOperation(
                deviceID: firstDevice, sequence: 1, captureID: record.id, baseRevision: 0,
                mutation: .create(record)))
        _ = try fixture.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: record.id, baseRevision: 0,
                mutation: .edit(
                    CaptureEdit(note: NoteEdit(String(repeating: "b", count: 4 * 1_048_576))))))
        try fixture.store.pull(from: fixture.server)
        let current = try #require(try fixture.store.capture(id: record.id))
        #expect(current.noteConflicts.count == 2)
        #expect(current.revision == 2)
        let before = try fixture.state()
        #expect(throws: CaptureValidationError.tooLarge) {
            try fixture.store.update(
                current, note: String(repeating: "c", count: 6 * 1_048_576), tags: [])
        }
        let unchanged = try fixture.state() == before
        #expect(unchanged)
        try fixture.store.update(
            current, note: "Resolved", tags: [], resolving: current.noteConflicts.map(\.operationID)
        )
        #expect(try fixture.store.pending().map(\.sequence) == [1])
        try fixture.store.push(to: fixture.server)
        #expect(try fixture.store.pending().isEmpty)
        record = try #require(try fixture.server.baseline().captures.first)
        let resolved = record.note == "Resolved" && record.noteConflicts.isEmpty
        #expect(resolved)
    }

    @Test func largeSafeRepliesRemainAccepted() throws {
        let fixture = try ResponseBudgetFixture()
        defer { fixture.clean() }
        let capture = try CaptureInput.make(
            text: String(repeating: "s", count: 8 * 1_048_576), isLink: false)
        try fixture.store.save(capture)
        let note = String(repeating: "n", count: 6 * 1_048_576)
        try fixture.store.update(id: capture.id, note: note, tags: ["manual"])
        #expect(try fixture.store.pending().map(\.sequence) == [1, 2])
        try fixture.store.push(to: fixture.server)
        #expect(try fixture.store.pending().isEmpty)
        let matching = try fixture.server.baseline().captures.first?.note == note
        #expect(matching)
    }
}

private struct ResponseBudgetFixture {
    let root: URL
    let url: URL
    let store: MobileStore
    let server: SyncServer
    var principal: SyncPrincipal {
        SyncPrincipal(
            serviceID: store.deviceID, libraryID: store.deviceID, deviceID: store.deviceID)
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        url = root.appendingPathComponent("mobile.sqlite")
        store = try MobileStore(url: url)
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-blobs"))
    }
    func envelope(_ operation: SyncOperation) -> SyncHTTPEnvelope {
        SyncHTTPEnvelope(
            expectedServiceID: store.deviceID, expectedLibraryID: store.deviceID,
            expectedDeviceID: store.deviceID, action: .apply(operation))
    }
    func records() throws -> [SharedCapture] {
        try store.contentSnapshotImport(
            snapshotID: UUID(),
            targetBinding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        ).captures
    }
    func state() throws -> ResponseBudgetState {
        let reader = try DatabaseQueue(path: url.path)
        return try reader.read { db in
            ResponseBudgetState(
                sequence: try Int64.fetchOne(db, sql: "SELECT sequence FROM sync_meta")!,
                pending: try Data.fetchAll(
                    db, sql: "SELECT payload FROM sync_outbox ORDER BY sequence"),
                records: try Data.fetchAll(db, sql: "SELECT payload FROM sync_visible ORDER BY id"),
                captures: try MobileCapture.order(Column("id")).fetchAll(db))
        }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct ResponseBudgetState: Equatable {
    let sequence: Int64
    let pending: [Data]
    let records: [Data]
    let captures: [MobileCapture]
}
