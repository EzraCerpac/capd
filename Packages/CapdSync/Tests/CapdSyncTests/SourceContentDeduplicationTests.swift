import Foundation
import GRDB
import Testing

@testable import CapdSync

struct SourceContentDeduplicationTests {
    @Test(arguments: ["nil", "empty", "accepted"], ["nil", "empty", "incoming"])
    func duplicateCreateUsesExistingSourceFillSemantics(canonical: String, incoming: String) throws
    {
        let f = try SourceFillFixture()
        defer { f.clean() }
        var original = SharedCapture(
            source: CaptureSource(
                kind: .link, contentHash: "source-fill", url: "https://example.com/fill",
                title: value(canonical), selection: value(canonical)),
            createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        original.source.unknownFields = ["retained": .bool(true)]
        original.generated = GeneratedContent(
            body: "Accepted body", ocrText: "Accepted OCR", tags: ["generated"])
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: original.id,
                baseRevision: 0, mutation: .create(original)))
        try f.client.pull(from: f.transport)
        let duplicate = SharedCapture(
            source: CaptureSource(
                kind: .link, contentHash: original.source.contentHash, url: original.source.url,
                title: value(incoming), selection: value(incoming)))
        let operation = try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        #expect(operation.captureID == duplicate.id)
        #expect(operation.baseRevision == 0)
        #expect(operation.sequence == 1)
        let expected =
            canonical == "accepted" || incoming != "incoming" ? value(canonical) : value(incoming)
        let optimistic = try #require(try f.client.captures().first)
        #expect(optimistic.id == original.id)
        #expect(optimistic.source.title == expected)
        #expect(optimistic.source.selection == expected)
        let later = try f.client.enqueue(
            captureID: duplicate.id, mutation: .edit(CaptureEdit(note: NoteEdit("Later note"))))
        #expect(later.predecessorID == operation.id)
        let receipts = try f.client.push(to: f.transport)
        #expect(receipts.map(\.outcome) == [.accepted, .accepted])
        #expect(receipts.first?.capture?.source.title == expected)
        #expect(receipts.first?.capture?.source.selection == expected)
        let accepted = try #require(try f.server.baseline().captures.first)
        #expect(accepted.id == original.id)
        #expect(accepted.createdAt == original.createdAt)
        #expect(accepted.generated == original.generated)
        #expect(accepted.source.unknownFields == original.source.unknownFields)
        #expect(accepted.source.url == original.source.url)
        #expect(accepted.source.contentHash == original.source.contentHash)
        #expect(accepted.source.title == expected)
        #expect(accepted.source.selection == expected)
        #expect(accepted.note == "Later note")
        #expect(accepted.noteConflicts.isEmpty)
        #expect(accepted.seenCount == 2)
        try f.client.pull(from: f.transport)
        #expect(try f.client.captures() == [accepted])
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test func filledDuplicateStillObeysReplyBudgetAndRollsBackAliases() throws {
        let f = try SourceFillFixture()
        defer { f.clean() }
        var original = SharedCapture(
            source: CaptureSource(
                kind: .link, contentHash: "large-fill",
                url: "https://example.com/large-fill"))
        original.generated.body = String(repeating: "b", count: 9_000_000)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: original.id,
                baseRevision: 0, mutation: .create(original)))
        try f.client.pull(from: f.transport)
        let before = try f.client.captures()
        let baseline = try f.server.baseline()
        let duplicate = SharedCapture(
            source: CaptureSource(
                kind: .link, contentHash: original.source.contentHash,
                url: original.source.url, selection: String(repeating: "s", count: 9_000_000)))
        #expect(throws: SyncHTTPError.resourceLimit) {
            try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        }
        #expect(try f.client.captures() == before)
        #expect(try f.client.pendingOperations().isEmpty)
        #expect(
            try f.writer.read { try Int64.fetchOne($0, sql: "SELECT sequence FROM sync_meta") } == 0
        )
        #expect(
            try f.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_aliases") }
                == 0)
        let raw = SyncOperation(
            deviceID: f.client.deviceID, sequence: 1, captureID: duplicate.id,
            baseRevision: 0, mutation: .create(duplicate))
        #expect(throws: SyncHTTPError.resourceLimit) { try f.transport.apply(raw) }
        #expect(try f.server.baseline() == baseline)
        #expect(try f.server.changes(after: baseline.cursor).changes.isEmpty)
        var safe = duplicate
        safe.source.selection = "Safe selection"
        let queued = try f.client.enqueue(captureID: safe.id, mutation: .create(safe))
        #expect(queued.sequence == raw.sequence)
        #expect(try f.client.push(to: f.transport).first?.outcome == .accepted)
        #expect(try f.server.baseline().captures.first?.source.selection == safe.source.selection)
        #expect(try f.server.baseline().captures.first?.generated.body == original.generated.body)
        #expect(try f.client.pendingOperations().isEmpty)
    }

    private func value(_ kind: String) -> String? {
        switch kind {
        case "nil": nil
        case "empty": ""
        default: kind
        }
    }
}

private struct SourceFillFixture {
    let root: URL
    let writer: DatabaseQueue
    let server: SyncServer
    let client: SyncClient
    let transport: SyncHTTPTransport

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-source-fill-\(UUID())")
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        writer = try DatabaseQueue(path: root.appendingPathComponent("client.sqlite").path)
        client = try SyncClient(
            writer: writer,
            blobs: BlobStore(
                directory: root.appendingPathComponent("client-blobs"), binding: binding),
            binding: binding)
        let handler = SyncHTTPHandler(
            serviceID: binding.serviceID,
            authorizer: SourceFillAuthorizer(
                principal: SyncPrincipal(
                    serviceID: binding.serviceID,
                    libraryID: binding.libraryID, deviceID: client.deviceID)),
            server: { [server] _ in server })
        transport = SyncHTTPTransport(
            binding: binding, deviceID: client.deviceID,
            credential: { "synthetic-source-fill" }, execute: { handler.handle($0) })
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct SourceFillAuthorizer: SyncAuthorizer {
    let principal: SyncPrincipal
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        bearerCredential == "synthetic-source-fill" ? principal : nil
    }
}
