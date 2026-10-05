import Foundation
import GRDB
import Testing

@testable import CapdSync

struct ClientResponseValidationTests {
    @Test func sameIDCreateReceiptMustPreserveSource() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let incoming = f.capture("incoming")
        let operation = try f.client.enqueue(captureID: incoming.id, mutation: .create(incoming))
        var unrelated = SharedCapture(id: incoming.id, source: f.capture("unrelated").source)
        unrelated.revision = 1
        let receipt = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: unrelated)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: receipt))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == [incoming])
    }

    @Test(arguments: [false, true])
    func recaptureReceiptMustAdvanceRevisionAndCount(advanceRevision: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("recapture")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let operation = try f.client.enqueue(captureID: original.id, mutation: .recapture)
        let before = try f.client.captures()
        var unchanged = try #require(f.server.baseline().captures.first)
        if advanceRevision { unchanged.revision += 1 }
        let receipt = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: unchanged)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: receipt))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == before)
    }

    @Test(arguments: [-1, 3])
    func baselineRevisionMustBeWithinSnapshot(revision: Int64) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("baseline")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        let before = try f.client.captures()
        var poisoned = try #require(before.first)
        poisoned.revision = revision
        let baseline = Baseline(cursor: 2, captures: [poisoned], deviceSequences: [:])
        #expect(throws: SyncError.invalidCursor) {
            try f.client.pull(from: ResponseTransport(server: f.server, snapshot: baseline))
        }
        #expect(try f.client.captures() == before)
        #expect(try f.client.cursor() == 1)
    }

    @Test func duplicateBaselineIDsDoNotReplaceShadow() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        for name in ["first", "second"] {
            let record = f.capture(name)
            try f.client.enqueue(captureID: record.id, mutation: .create(record))
        }
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        let before = try f.client.captures()
        let first = try #require(before.first)
        let baseline = Baseline(cursor: 2, captures: [first, first], deviceSequences: [:])
        #expect(throws: SyncError.invalidCursor) {
            try f.client.pull(from: ResponseTransport(server: f.server, snapshot: baseline))
        }
        #expect(try f.client.captures() == before)
        #expect(try f.client.cursor() == 2)
    }

    @Test(arguments: [false, true])
    func uncorrelatedLocalFeedAliasRollsBack(pending: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let incoming = f.capture("requested")
        let operation =
            pending
            ? try f.client.enqueue(captureID: incoming.id, mutation: .create(incoming))
            : SyncOperation(
                deviceID: f.client.deviceID, sequence: 1, captureID: incoming.id,
                baseRevision: 0, mutation: .create(incoming))
        let before = try f.client.captures()
        var unrelated = f.capture("unrelated")
        unrelated.revision = 1
        let page = FeedPage(
            cursor: 1,
            changes: [
                FeedChange(
                    cursor: 1, operationID: operation.id, deviceID: f.client.deviceID,
                    sequence: operation.sequence, requestedCaptureID: incoming.id,
                    capture: unrelated)
            ])
        #expect(throws: SyncError.invalidOperation) {
            try f.client.pull(from: ResponseTransport(server: f.server, page: page))
        }
        #expect(try f.client.captures() == before)
        #expect(try f.client.cursor() == 0)
        let alias = try f.writer.read { try SyncDatabase.canonical($0, incoming.id) }
        let observed = try f.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_observed")
        }
        #expect(alias == incoming.id)
        #expect(observed == 0)
        if pending {
            #expect(try f.client.pendingOperations() == [operation])
            try f.client.push(to: f.server)
        }
    }

    @Test func historicalReceiptsSurviveOwnEchoAndLaterRemoteEdits() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        var record = f.capture("historical")
        record.source.title = ""
        record.source.selection = ""
        try f.client.enqueue(captureID: record.id, mutation: .create(record))
        try f.client.push(to: f.server)
        let recapture = try f.client.enqueue(captureID: record.id, mutation: .recapture)
        let historical = try f.server.apply(recapture)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: record.id,
                baseRevision: historical.capture!.revision,
                mutation: .edit(
                    CaptureEdit(
                        rating: 5,
                        sourceContent: SourceContentPatch(
                            title: "Filled title", selection: "Filled text")))))
        try f.client.pull(from: f.server)
        let latest = try f.client.captures()
        #expect(try f.client.push(to: f.server) == [historical])
        #expect(try f.client.captures() == latest)
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test func remoteShadowDoesNotProvePendingOperationWasAccepted() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("unobserved")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let operation = try f.client.enqueue(captureID: original.id, mutation: .recapture)
        let remote = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: original.id,
                baseRevision: operation.baseRevision, mutation: .recapture))
        try f.client.pull(from: f.server)
        let before = try f.client.captures()
        let forged = SyncReceipt(
            operationID: operation.id, outcome: .accepted, capture: remote.capture)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == before)
        try f.client.push(to: f.server)
        #expect(try f.client.captures().first?.seenCount == 3)
    }

    @Test func unchangedRecaptureEchoCannotProveAcceptance() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("unchanged echo")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        let operation = try f.client.enqueue(captureID: original.id, mutation: .recapture)
        let before = try f.client.captures()
        var unchanged = try #require(f.server.baseline().captures.first)
        unchanged.revision += 1
        let page = FeedPage(
            cursor: unchanged.revision,
            changes: [
                FeedChange(
                    cursor: unchanged.revision, operationID: operation.id,
                    deviceID: f.client.deviceID, sequence: operation.sequence,
                    requestedCaptureID: original.id, capture: unchanged)
            ])
        let forged = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: unchanged)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.pull(from: ResponseTransport(server: f.server, page: page))
        }
        #expect(try f.client.cursor() == operation.baseRevision)
        #expect(try f.client.captures() == before)
        let observed = try f.writer.read {
            try Int.fetchOne(
                $0, sql: "SELECT COUNT(*) FROM sync_observed WHERE id = ?",
                arguments: [operation.id.uuidString])
        }
        #expect(observed == 0)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == before)
        try f.client.push(to: f.server)
        #expect(try f.client.captures().first?.seenCount == 2)
    }

    @Test(arguments: [false, true])
    func pendingNoteConflictEchoRemainsValid(duplicateCreate: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("conflict echo")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: original.id, baseRevision: 1,
                mutation: .edit(CaptureEdit(note: NoteEdit("Remote")))))
        let operation: SyncOperation
        if duplicateCreate {
            let duplicate = SharedCapture(source: original.source, note: "Local")
            operation = try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        } else {
            operation = try f.client.enqueue(
                captureID: original.id, mutation: .edit(CaptureEdit(note: NoteEdit("Local"))))
        }
        let historical = try f.server.apply(operation)
        #expect(historical.outcome == .noteConflict)
        try f.client.pull(from: f.server)
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.push(to: f.server) == [historical])
        let accepted = try #require(f.client.captures().first)
        #expect(Set(accepted.noteConflicts.compactMap(\.value)) == ["Remote", "Local"])
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test func acceptedEditReceiptMustContainRequestedRating() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("edit")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let operation = try f.client.enqueue(
            captureID: original.id, mutation: .edit(CaptureEdit(rating: 5)))
        var unchanged = try #require(f.server.baseline().captures.first)
        unchanged.revision += 1
        let forged = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: unchanged)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures().first?.rating == 5)
    }

    @Test(arguments: [Int.max - 1, Int.max])
    func acceptedRecaptureCountCanSaturate(count: Int) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("saturated")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        var current = try #require(f.server.baseline().captures.first)
        current.seenCount = count
        let authority = try SyncDatabase.open(at: f.root.appendingPathComponent("server.sqlite"))
        try authority.write { try SyncDatabase.save($0, current) }
        try f.writer.write { try SyncDatabase.save($0, current) }
        try f.client.enqueue(captureID: original.id, mutation: .recapture)
        #expect(try f.client.push(to: f.server).first?.capture?.seenCount == Int.max)
        #expect(try f.client.pendingOperations().isEmpty)
        #expect(try f.client.captures().first?.seenCount == Int.max)
    }

    @Test(arguments: [false, true])
    func acceptedExistingNoteVariantRemainsValid(duplicateCreate: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("conflict")
        let created = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: original.id, baseRevision: 0,
                mutation: .create(original)))
        let base = try #require(created.capture).revision
        for value in ["A", "B"] {
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: original.id, baseRevision: base,
                    mutation: .edit(CaptureEdit(note: NoteEdit(value)))))
        }
        try f.client.pull(from: f.server)
        if duplicateCreate {
            let duplicate = SharedCapture(source: original.source, note: "B")
            try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        } else {
            try f.client.enqueue(
                captureID: original.id, mutation: .edit(CaptureEdit(note: NoteEdit("B"))),
                baseRevision: base)
        }
        #expect(try f.client.push(to: f.server).first?.outcome == .accepted)
        let accepted = try #require(f.client.captures().first)
        #expect(accepted.note == "A")
        #expect(Set(accepted.noteConflicts.compactMap(\.value)) == ["A", "B"])
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test func pendingDeduplicatedCreateAndEstablishedAliasFeedRemainValid() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let first = f.capture("dedup")
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: first.id, baseRevision: 0,
                mutation: .create(first)))
        let duplicate = SharedCapture(source: first.source)
        let create = try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        _ = try f.server.apply(create)
        try f.client.pull(from: f.server)
        #expect(try f.client.captures().first?.seenCount == 2)
        try f.client.push(to: f.server)
        let edit = try f.client.enqueue(
            captureID: duplicate.id, mutation: .edit(CaptureEdit(rating: 4)))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        #expect(try f.client.captures().first?.rating == 4)
        #expect(edit.captureID == duplicate.id)
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test func exhaustedSequenceThrowsWithoutMutatingOutbox() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let baseline = Baseline(
            cursor: 0, captures: [], deviceSequences: [f.client.deviceID: Int64.max])
        try f.client.pull(from: ResponseTransport(server: f.server, snapshot: baseline))
        let record = f.capture("exhausted")
        #expect(throws: SyncError.invalidOperation) {
            try f.client.enqueue(captureID: record.id, mutation: .create(record))
        }
        #expect(try f.client.pendingOperations().isEmpty)
        #expect(try f.client.captures().isEmpty)
        #expect(
            try f.writer.read { try Int64.fetchOne($0, sql: "SELECT sequence FROM sync_meta") }
                == Int64.max)
    }
}

private struct ResponseTransport: SyncTransport {
    let server: SyncServer
    var receipt: SyncReceipt? = nil
    var snapshot: Baseline? = nil
    var page: FeedPage? = nil

    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        if let receipt { return receipt }
        return try server.apply(operation)
    }

    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        if snapshot != nil { throw SyncError.cursorExpired }
        if let page { return page }
        return try server.changes(after: cursor, limit: limit)
    }

    func baseline() throws -> Baseline {
        if let snapshot { return snapshot }
        return try server.baseline()
    }

    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }

    func download(_ blob: BlobReference) throws -> Data { try server.download(blob) }
}

private struct ResponseFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let writer: DatabasePool
    let client: SyncClient
    let server: SyncServer

    init() throws {
        writer = try SyncDatabase.open(at: root.appendingPathComponent("client.sqlite"))
        client = try SyncClient(
            writer: writer, blobs: BlobStore(directory: root.appendingPathComponent("client-blobs"))
        )
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-blobs"))
    }

    func capture(_ value: String) -> SharedCapture {
        SharedCapture(source: CaptureSource(kind: .text, contentHash: value, selection: value))
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
