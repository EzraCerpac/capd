import Foundation
import Testing

@testable import CapdSync

@Suite("Synthetic device recovery and overlapping blob retries")
struct RecoveryAndBlobRetryTests {
    @Test func recreatedDeviceContinuesAcceptedSequenceAfterReopen() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.clean() }
        let record = SharedCapture(
            source: CaptureSource(kind: .text, selection: "recovered device"))
        let original = try fixture.client("original")
        try original.enqueue(captureID: record.id, mutation: .create(record))
        try original.enqueue(captureID: record.id, mutation: .recapture)
        try original.push(to: fixture.server)
        try fixture.server.expireFeed(through: fixture.server.baseline().cursor)

        try fixture.client("recovered").pull(from: fixture.server)
        let reopened = try fixture.client("recovered")
        let operation = try reopened.enqueue(captureID: record.id, mutation: .recapture)
        #expect(operation.sequence == 3)
        #expect(try reopened.push(to: fixture.server).first?.outcome == .accepted)
        #expect(try fixture.server.baseline().deviceSequences[fixture.deviceID] == 3)
    }

    @Test func baselineRefusesAmbiguousSequencesWithoutSuppressingPendingOperations() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.clean() }
        let original = try fixture.client("original")
        let accepted = SharedCapture(source: CaptureSource(kind: .text, selection: "accepted"))
        try original.enqueue(captureID: accepted.id, mutation: .create(accepted))
        try original.push(to: fixture.server)
        try fixture.server.expireFeed(through: fixture.server.baseline().cursor)

        let recovered = try fixture.client("recovered")
        for index in 0..<3 {
            let record = SharedCapture(
                source: CaptureSource(kind: .text, selection: "pending \(index)"))
            try recovered.enqueue(captureID: record.id, mutation: .create(record))
        }
        let pending = try recovered.pendingOperations()
        let visible = try recovered.captures()
        #expect(throws: SyncError.recoverySequenceCollision) {
            try recovered.pull(from: fixture.server)
        }
        #expect(try recovered.pendingOperations() == pending)
        #expect(try recovered.captures() == visible)
        #expect(try recovered.cursor() == 0)
        let reopened = try fixture.client("recovered")
        #expect(try reopened.pendingOperations() == pending)
        #expect(try reopened.captures() == visible)
        #expect(throws: SyncError.recoverySequenceCollision) {
            try reopened.pull(from: fixture.server)
        }
        let next = SharedCapture(source: CaptureSource(kind: .text, selection: "next"))
        #expect(try reopened.enqueue(captureID: next.id, mutation: .create(next)).sequence == 4)
    }

    @Test func lostAcknowledgementCanRetryUnchangedBeforeBaselineRecovery() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.clean() }
        let client = try fixture.client("original")
        let record = SharedCapture(source: CaptureSource(kind: .text, selection: "lost ack"))
        let operation = try client.enqueue(captureID: record.id, mutation: .create(record))
        try fixture.server.apply(operation)
        try fixture.server.expireFeed(through: fixture.server.baseline().cursor)
        #expect(throws: SyncError.recoverySequenceCollision) {
            try client.pull(from: fixture.server)
        }
        #expect(try client.pendingOperations() == [operation])
        #expect(try client.push(to: fixture.server).first?.operationID == operation.id)
        try client.pull(from: fixture.server)
        #expect(try client.pendingOperations().isEmpty)
        #expect(try client.captures().first?.seenCount == 1)
        #expect(try client.enqueue(captureID: record.id, mutation: .recapture).sequence == 2)
    }

    @Test(arguments: [0, 3])
    func matchingRetryExtendsPartialAfterReopen(offset: Int) throws {
        let fixture = try RecoveryFixture()
        defer { fixture.clean() }
        let bytes = Data("synthetic longer upload".utf8)
        let blob = BlobReference(data: bytes)
        let directory = fixture.root.appendingPathComponent("retry-blobs")
        try BlobStore(directory: directory).receive(
            blob, offset: 0, chunk: bytes.prefix(5), final: false)
        let reopened = try BlobStore(directory: directory)
        try reopened.receive(blob, offset: offset, chunk: bytes.dropFirst(offset), final: true)
        #expect(try reopened.read(blob) == bytes)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(blob.digest + ".partial").path))
    }

    @Test func mismatchingRetryPreservesPartialForValidRetry() throws {
        let fixture = try RecoveryFixture()
        defer { fixture.clean() }
        let bytes = Data("synthetic longer upload".utf8)
        let blob = BlobReference(data: bytes)
        let store = try BlobStore(directory: fixture.root.appendingPathComponent("retry-blobs"))
        try store.receive(blob, offset: 0, chunk: bytes.prefix(5), final: false)
        var changed = bytes
        changed[0] ^= 1
        #expect(throws: SyncError.invalidOffset) {
            try store.receive(blob, offset: 0, chunk: changed, final: true)
        }
        #expect(throws: SyncError.blobMissing) { try store.read(blob) }
        try store.receive(blob, offset: 0, chunk: bytes, final: true)
        #expect(try store.read(blob) == bytes)
    }
}

private struct RecoveryFixture {
    let root: URL
    let server: SyncServer
    let deviceID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-blobs"))
    }

    func client(_ name: String) throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("\(name).sqlite"),
            blobDirectory: root.appendingPathComponent("\(name)-blobs"), deviceID: deviceID)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
