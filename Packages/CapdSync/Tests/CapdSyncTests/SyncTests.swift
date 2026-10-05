import Foundation
import GRDB
import Testing

@testable import CapdSync

@Suite("Synthetic offline sync")
struct SyncTests {
    @Test(
        "A queued independent-field edit cannot hide a concurrent note from the next offline note edit"
    )
    func independentPredecessor() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let b = try f.client("b")
        let record = text("field causality")
        try a.enqueue(captureID: record.id, mutation: .create(record))
        try a.push(to: f.server)
        try b.pull(from: f.server)
        try b.enqueue(captureID: record.id, mutation: .edit(CaptureEdit(rating: 4)))
        try b.enqueue(captureID: record.id, mutation: .edit(CaptureEdit(note: NoteEdit("B"))))
        try a.enqueue(captureID: record.id, mutation: .edit(CaptureEdit(note: NoteEdit("A"))))
        try a.push(to: f.server)
        try b.push(to: f.server)
        #expect(
            Set(try f.server.baseline().captures.first!.noteConflicts.compactMap(\.value)) == [
                "A", "B",
            ])
        #expect(try f.server.baseline().captures.first?.rating == 4)
    }

    @Test("A corrupt local blob cache is replaced only by verified server bytes")
    func repairBlobCache() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let bytes = Data("good cache bytes".utf8)
        let blob = try a.blobs.put(bytes)
        let record = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        try a.enqueue(captureID: record.id, mutation: .create(record))
        try a.push(to: f.server)
        let b = try f.client("b")
        let path = b.blobs.directory.appendingPathComponent(blob.digest)
        try Data("bad".utf8).write(to: path, options: .atomic)
        try b.pull(from: f.server)
        #expect(try b.blobs.read(blob) == bytes)
        #expect(try b.captures().first?.id == record.id)
    }

    @Test(
        "Own feed echo proves acceptance; ambiguous expired recovery preserves work for receipt retry"
    )
    func lostAcknowledgementPull() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let record = text("own echo")
        try a.enqueue(captureID: record.id, mutation: .create(record))
        let lost = DroppingTransport(server: f.server)
        #expect(throws: SyncError.acknowledgementLost) { try a.push(to: lost) }
        try a.pull(from: f.server)
        #expect(try a.captures().first?.seenCount == 1)
        #expect(try a.pendingOperations().count == 1)
        try a.push(to: lost)
        try a.enqueue(captureID: record.id, mutation: .recapture)
        lost.dropNext()
        #expect(throws: SyncError.acknowledgementLost) { try a.push(to: lost) }
        try f.server.expireFeed(through: f.server.baseline().cursor)
        let pending = try a.pendingOperations()
        let visible = try a.captures()
        #expect(throws: SyncError.recoverySequenceCollision) { try a.pull(from: f.server) }
        #expect(try a.pendingOperations() == pending)
        #expect(try a.captures() == visible)
        #expect(try a.captures().first?.seenCount == 2)
        #expect(try a.pendingOperations().count == 1)
        try a.push(to: lost)
        try a.pull(from: f.server)
        #expect(try a.captures().first?.seenCount == 2)
        #expect(try a.pendingOperations().isEmpty)
    }

    @Test(
        "A stale conflict resolution remains an unsent overlay and becomes another preserved variant"
    )
    func staleResolution() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let b = try f.client("b")
        let record = text("resolution")
        try a.enqueue(captureID: record.id, mutation: .create(record))
        try a.push(to: f.server)
        try b.pull(from: f.server)
        try a.enqueue(captureID: record.id, mutation: .edit(CaptureEdit(note: NoteEdit("A"))))
        try b.enqueue(captureID: record.id, mutation: .edit(CaptureEdit(note: NoteEdit("B"))))
        try a.push(to: f.server)
        try b.push(to: f.server)
        try a.pull(from: f.server)
        let conflicts = try a.captures().first!.noteConflicts.map(\.operationID)
        try a.enqueue(
            captureID: record.id,
            mutation: .edit(CaptureEdit(note: NoteEdit("A resolved", resolving: conflicts))))
        try b.enqueue(
            captureID: record.id,
            mutation: .edit(CaptureEdit(note: NoteEdit("B resolved", resolving: conflicts))))
        try b.push(to: f.server)
        try a.pull(from: f.server)
        #expect(try a.captures().first?.note == "A resolved")
        try a.push(to: f.server)
        let variants = try f.server.baseline().captures.first!.noteConflicts.compactMap(\.value)
        #expect(Set(variants) == ["A resolved", "B resolved"])
        #expect(try a.pendingOperations().isEmpty)
    }

    @Test("A rejected predecessor cannot grant restoration at an unseen tombstone revision")
    func restoreDoesNotRebase() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let b = try f.client("b")
        let record = text("unseen deletion")
        try a.enqueue(captureID: record.id, mutation: .create(record))
        try a.push(to: f.server)
        try b.pull(from: f.server)
        try b.enqueue(captureID: record.id, mutation: .edit(CaptureEdit(note: NoteEdit("stale"))))
        try b.enqueue(captureID: record.id, mutation: .restore)
        try a.enqueue(captureID: record.id, mutation: .delete)
        try a.push(to: f.server)
        try b.push(to: f.server)
        #expect(try f.server.baseline().captures.first?.deleted == true)
        #expect(Set(try b.rejectedWork().map(\.receipt.outcome)) == [.deleted, .staleRestore])
    }

    @Test("Offline create/edit/delete survives reopen and reconnect without pull echo")
    func offlineLifecycle() throws {
        let f = try Fixture()
        defer { f.clean() }
        let device = UUID()
        var client = try f.client("a", device: device)
        let record = text("offline")
        try client.enqueue(captureID: record.id, mutation: .create(record))
        try client.enqueue(
            captureID: record.id, mutation: .edit(CaptureEdit(note: NoteEdit("first edit"))))
        try client.enqueue(
            captureID: record.id,
            mutation: .edit(CaptureEdit(note: NoteEdit("second edit"), rating: 5)))
        #expect(try client.captures().first?.note == "second edit")
        client = try f.client("a", device: device)
        #expect(try client.pendingOperations().count == 3)
        let transport = LoopbackTransport(server: f.server)
        try client.push(to: transport)
        let accepted = try f.server.baseline().captures.first!
        #expect(try f.server.reader.acceptedCaptures() == [accepted])
        #expect(accepted.note == "second edit")
        #expect(accepted.noteConflicts.isEmpty)
        #expect(accepted.rating == 5)
        let other = try f.client("b")
        try other.pull(from: transport)
        #expect(try other.captures().first == accepted)
        #expect(try other.pendingOperations().isEmpty)
        try client.enqueue(captureID: record.id, mutation: .delete)
        #expect(try client.captures().isEmpty)
        try client.push(to: transport)
        try other.pull(from: transport)
        #expect(try other.captures().isEmpty)
        #expect(try f.server.reader.acceptedCaptures().isEmpty)
        #expect(try other.captures(includeDeleted: true).first?.deleted == true)
        #expect(try client.pendingOperations().isEmpty)
    }

    @Test("Duplicate requests and lost acknowledgement do not repeat recapture or feed writes")
    func idempotency() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let record = text("dedup")
        let create = try a.enqueue(captureID: record.id, mutation: .create(record))
        let lost = DroppingTransport(server: f.server)
        #expect(throws: SyncError.acknowledgementLost) { try a.push(to: lost) }
        #expect(try a.pendingOperations() == [create])
        #expect(try f.server.baseline().captures.count == 1)
        try a.push(to: lost)
        let recapture = try a.enqueue(captureID: record.id, mutation: .recapture)
        lost.dropNext()
        #expect(throws: SyncError.acknowledgementLost) { try a.push(to: lost) }
        let reopened = try f.reopenServer()
        let receipt = try reopened.apply(recapture)
        #expect(receipt.capture?.seenCount == 2)
        #expect(try reopened.apply(recapture) == receipt)
        #expect(try reopened.changes(after: 0).changes.count == 2)
        try a.push(to: LoopbackTransport(server: reopened))
        #expect(try a.captures().first?.seenCount == 2)
        var different = record
        different.note = "different payload"
        let reused = SyncOperation(
            id: create.id, deviceID: create.deviceID,
            sequence: create.sequence, captureID: record.id, baseRevision: 0,
            mutation: .create(different))
        #expect(throws: SyncError.operationIDReused) { try reopened.apply(reused) }
    }

    @Test("Cross-device fingerprint dedupe reconciles aliases without rewriting operation IDs")
    func contentDedupe() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let b = try f.client("b")
        let first = text("shared fingerprint")
        let second = text("shared fingerprint")
        #expect(first.id != second.id)
        try a.enqueue(captureID: first.id, mutation: .create(first))
        try b.enqueue(captureID: second.id, mutation: .create(second))
        let edit = try b.enqueue(
            captureID: second.id,
            mutation: .edit(CaptureEdit(note: NoteEdit("offline alias edit"))))
        try a.push(to: f.server)
        try b.push(to: f.server)
        #expect(edit.captureID == second.id)
        #expect(try f.server.baseline().captures.count == 1)
        #expect(try b.captures().first?.id == first.id)
        #expect(try b.captures().first?.seenCount == 2)
        #expect(try b.captures().first?.note == "offline alias edit")
        #expect(try b.captures().first?.noteConflicts.isEmpty == true)
        try a.pull(from: f.server)
        #expect(try a.captures() == b.captures())
    }

    @Test(
        "Concurrent note edits preserve both variants; explicit resolution merges independent fields"
    )
    func concurrentNotes() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let b = try f.client("b")
        let record = text("notes", note: "original")
        try a.enqueue(captureID: record.id, mutation: .create(record))
        try a.push(to: f.server)
        try a.pull(from: f.server)
        try b.pull(from: f.server)
        try a.enqueue(
            captureID: record.id,
            mutation: .edit(CaptureEdit(note: NoteEdit("A"), addTags: ["manual-a"])))
        try b.enqueue(
            captureID: record.id,
            mutation: .edit(
                CaptureEdit(
                    note: NoteEdit("B"), rating: 4,
                    addTags: ["manual-b"],
                    generated: GeneratedContent(body: "synthetic body", tags: ["generated"]))))
        try a.push(to: f.server)
        try b.push(to: f.server)
        let conflict = try f.server.baseline().captures.first!
        #expect(Set(conflict.noteConflicts.compactMap(\.value)) == ["A", "B"])
        #expect(conflict.manualTags == ["manual-a", "manual-b"])
        #expect(conflict.generated.tags == ["generated"])
        #expect(conflict.rating == 4)
        try a.pull(from: f.server)
        try a.enqueue(
            captureID: record.id,
            mutation: .edit(
                CaptureEdit(
                    note: NoteEdit("A and B", resolving: conflict.noteConflicts.map(\.operationID)))
            ))
        try a.push(to: f.server)
        try b.pull(from: f.server)
        #expect(try b.captures().first?.note == "A and B")
        #expect(try b.captures().first?.noteConflicts.isEmpty == true)
    }

    @Test(
        "Pull keeps unsent local overlay and does not echo it; acknowledgement avoids revision rollback"
    )
    func pendingOverlay() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let b = try f.client("b")
        let record = text("overlay")
        try a.enqueue(captureID: record.id, mutation: .create(record))
        try a.push(to: f.server)
        try b.pull(from: f.server)
        let local = try b.enqueue(
            captureID: record.id,
            mutation: .edit(CaptureEdit(note: NoteEdit("unsent"))))
        try a.enqueue(captureID: record.id, mutation: .edit(CaptureEdit(rating: 5)))
        try a.push(to: f.server)
        try b.pull(from: f.server)
        #expect(try b.captures().first?.note == "unsent")
        #expect(try b.captures().first?.rating == 5)
        #expect(try b.pendingOperations() == [local])
        try b.push(to: f.server)
        #expect(try b.captures().first?.noteConflicts.isEmpty == true)
    }

    @Test(
        "Tombstone blocks stale edits, recaptures, and hash creates; restoration requires exact revision"
    )
    func deletionAndRestoration() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let stale = try f.client("stale")
        let record = text("delete")
        try a.enqueue(captureID: record.id, mutation: .create(record))
        try a.push(to: f.server)
        try stale.pull(from: f.server)
        let rejected = try stale.enqueue(
            captureID: record.id,
            mutation: .edit(CaptureEdit(note: NoteEdit("valuable stale note"))))
        try a.enqueue(captureID: record.id, mutation: .delete)
        try a.push(to: f.server)
        try stale.push(to: f.server)
        #expect(try stale.captures().isEmpty)
        #expect(try stale.rejectedWork().first?.operation == rejected)
        try stale.enqueue(captureID: record.id, mutation: .recapture)
        try stale.push(to: f.server)
        let fresh = try f.client("fresh")
        let duplicate = text("delete")
        try fresh.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        try fresh.push(to: f.server)
        #expect(try f.server.baseline().captures.count == 1)
        #expect(try f.server.baseline().captures.first?.deleted == true)
        let badRestore = SyncOperation(
            deviceID: UUID(), sequence: 1,
            captureID: record.id, baseRevision: 1, mutation: .restore)
        #expect(try f.server.apply(badRestore).outcome == .staleRestore)
        try stale.pull(from: f.server)
        try stale.enqueue(captureID: record.id, mutation: .restore)
        try stale.push(to: f.server)
        #expect(try stale.captures().first?.deleted == false)
        #expect(try stale.captures().first?.seenCount == 1)
    }

    @Test(
        "Expired cursor baseline keeps pending edits, creates, deletes and their immutable operations"
    )
    func baselineRecovery() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let b = try f.client("b")
        let first = text("baseline")
        let doomed = text("doomed")
        for record in [first, doomed] {
            try a.enqueue(captureID: record.id, mutation: .create(record))
        }
        try a.push(to: f.server)
        try b.pull(from: f.server)
        let new = text("still offline")
        try b.enqueue(captureID: first.id, mutation: .edit(CaptureEdit(note: NoteEdit("keep me"))))
        try b.enqueue(captureID: new.id, mutation: .create(new))
        try b.enqueue(captureID: doomed.id, mutation: .delete)
        let pending = try b.pendingOperations()
        try a.enqueue(captureID: first.id, mutation: .edit(CaptureEdit(rating: 5)))
        try a.push(to: f.server)
        let cursor = try f.server.baseline().cursor
        try f.server.expireFeed(through: cursor)
        #expect(throws: SyncError.cursorExpired) { try f.server.changes(after: 0) }
        try b.pull(from: f.server)
        #expect(try b.cursor() == cursor)
        #expect(try b.pendingOperations() == pending)
        #expect(try b.captures().count == 2)
        #expect(try b.captures().first(where: { $0.id == first.id })?.note == "keep me")
        try b.push(to: f.server)
        try a.pull(from: f.server)
        #expect(try a.captures() == b.captures())
        #expect(try f.server.baseline().cursor > cursor)
    }

    @Test("Blob interruption, poison, retry and downloaded verification precede record publication")
    func blobTransfers() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let data = Data("tiny synthetic asset".utf8)
        let blob = try a.blobs.put(data)
        let record = SharedCapture(
            source: CaptureSource(kind: .image, contentHash: "image", blob: blob))
        let operation = try a.enqueue(captureID: record.id, mutation: .create(record))
        #expect(throws: SyncError.blobMissing) { try f.server.apply(operation) }
        try f.server.upload(blob, offset: 0, chunk: data.prefix(5), final: false)
        #expect(throws: SyncError.blobMissing) { try f.server.apply(operation) }
        try f.server.upload(blob, offset: 0, chunk: data.prefix(5), final: false)
        let reopened = try f.reopenServer()
        try reopened.upload(blob, offset: 5, chunk: data.dropFirst(5), final: true)
        #expect(try reopened.apply(operation).outcome == .accepted)
        let b = try f.client("b")
        try b.pull(from: LoopbackTransport(server: reopened))
        #expect(try b.blobs.read(blob) == data)
        #expect(try b.captures().first?.source.blob == blob)
        let bad = BlobReference(data: Data("expected".utf8))
        #expect(throws: SyncError.invalidBlob) {
            try reopened.upload(bad, offset: 0, chunk: Data("corrupt!".utf8), final: true)
        }
        #expect(throws: SyncError.blobMissing) { try reopened.download(bad) }
        try reopened.upload(bad, offset: 0, chunk: Data("expected".utf8), final: true)
        #expect(try reopened.download(bad) == Data("expected".utf8))
        #expect(throws: SyncError.invalidBlob) {
            try reopened.upload(
                BlobReference(digest: "../escape", byteCount: 1), offset: 0, chunk: Data([1]),
                final: true)
        }
    }

    @Test("Bad download cannot advance the cursor or publish a missing asset")
    func corruptDownload() throws {
        let f = try Fixture()
        defer { f.clean() }
        let a = try f.client("a")
        let blob = try a.blobs.put(Data("good".utf8))
        let record = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        try a.enqueue(captureID: record.id, mutation: .create(record))
        try a.push(to: f.server)
        let b = try f.client("b")
        #expect(throws: SyncError.invalidBlob) {
            try b.pull(from: CorruptDownload(server: f.server))
        }
        #expect(try b.cursor() == 0)
        #expect(try b.captures().isEmpty)
        try b.pull(from: f.server)
        #expect(try b.captures().first?.id == record.id)
    }

    @Test("Projection failure rolls back local edit plus outbox and pull plus cursor")
    func transactions() throws {
        let f = try Fixture()
        defer { f.clean() }
        let pool = try SyncDatabase.open(at: f.root.appendingPathComponent("atomic.sqlite"))
        let failure = FailureSwitch()
        let client = try SyncClient(
            writer: pool,
            blobs: BlobStore(directory: f.root.appendingPathComponent("atomic-blobs")),
            deviceID: UUID(), project: { _, _ in try failure.check() })
        let record = text("atomic")
        #expect(throws: SyncError.invalidOperation) {
            try client.enqueue(captureID: record.id, mutation: .create(record))
        }
        #expect(try client.pendingOperations().isEmpty)
        #expect(try client.captures().isEmpty)
        failure.set(false)
        let operation = try client.enqueue(captureID: record.id, mutation: .create(record))
        #expect(operation.sequence == 1)
        try client.push(to: f.server)
        let pullPool = try SyncDatabase.open(
            at: f.root.appendingPathComponent("pull-atomic.sqlite"))
        failure.set(true)
        let pullClient = try SyncClient(
            writer: pullPool,
            blobs: BlobStore(directory: f.root.appendingPathComponent("pull-blobs")),
            deviceID: UUID(),
            project: { _, _ in try failure.check() })
        #expect(throws: SyncError.invalidOperation) { try pullClient.pull(from: f.server) }
        #expect(try pullClient.cursor() == 0)
        #expect(try pullClient.captures().isEmpty)
        failure.set(false)
        try pullClient.pull(from: f.server)
        #expect(try pullClient.captures().first?.id == record.id)
    }

    @Test(
        "Device identity persists, ordering rejects gaps, and feed pages advance only consumed changes"
    )
    func orderingAndPagination() throws {
        let f = try Fixture()
        defer { f.clean() }
        let device = UUID()
        let a = try f.client("a", device: device)
        #expect(throws: SyncError.wrongDevice) { try f.client("a", device: UUID()) }
        let first = text("page 1")
        let second = text("page 2")
        let one = try a.enqueue(captureID: first.id, mutation: .create(first))
        let two = try a.enqueue(captureID: second.id, mutation: .create(second))
        #expect(throws: SyncError.outOfOrder(expected: 1)) { try f.server.apply(two) }
        _ = try f.server.apply(one)
        _ = try f.server.apply(two)
        let b = try f.client("b")
        try b.pull(from: f.server, limit: 1)
        #expect(try b.captures().count == 1)
        #expect(try b.cursor() == 1)
        try b.pull(from: f.server, limit: 1)
        #expect(try b.captures().count == 2)
        #expect(try b.cursor() == 2)
        #expect(throws: SyncError.invalidCursor) { try f.server.changes(after: 99) }
        #expect(throws: SyncError.invalidCursor) { try f.server.changes(after: 0, limit: 0) }
    }
}

private func text(_ hash: String, note: String? = nil) -> SharedCapture {
    SharedCapture(
        source: CaptureSource(
            kind: .text, contentHash: hash,
            title: "Synthetic \(hash)", selection: "source text"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), note: note)
}

private struct Fixture {
    let root: URL
    let server: SyncServer

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capd-sync-\(UUID())")
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-blobs"))
    }

    func client(_ name: String, device: UUID = UUID()) throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("\(name).sqlite"),
            blobDirectory: root.appendingPathComponent("\(name)-blobs"), deviceID: device)
    }

    func reopenServer() throws -> SyncServer {
        try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-blobs"))
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class FailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    func set(_ value: Bool) { lock.withLock { enabled = value } }
    func check() throws { try lock.withLock { if enabled { throw SyncError.invalidOperation } } }
}

private final class DroppingTransport: SyncTransport, @unchecked Sendable {
    let server: SyncServer
    private let lock = NSLock()
    private var shouldDrop = true
    init(server: SyncServer) { self.server = server }
    func dropNext() { lock.withLock { shouldDrop = true } }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        let receipt = try server.apply(operation)
        let drop = lock.withLock {
            let drop = shouldDrop
            shouldDrop = false
            return drop
        }
        if drop { throw SyncError.acknowledgementLost }
        return receipt
    }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try server.changes(after: cursor, limit: limit)
    }
    func baseline() throws -> Baseline { try server.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try server.download(blob) }
}

private struct CorruptDownload: SyncTransport {
    let server: SyncServer
    func apply(_ operation: SyncOperation) throws -> SyncReceipt { try server.apply(operation) }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try server.changes(after: cursor, limit: limit)
    }
    func baseline() throws -> Baseline { try server.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { Data("evil".utf8) }
}
