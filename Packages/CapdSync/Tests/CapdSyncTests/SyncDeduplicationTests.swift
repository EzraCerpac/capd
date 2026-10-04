import Foundation
import Testing

@testable import CapdSync

@Suite("Capture identity deduplication")
struct SyncDeduplicationTests {
    @Test(arguments: [CaptureSource.Kind.text, .image])
    func normalizedURLBytesDoNotAliasOtherKinds(_ kind: CaptureSource.Kind) throws {
        let fixture = try DeduplicationFixture()
        defer { fixture.clean() }
        let client = try fixture.client()
        let url = URL(string: "https://example.com/article?utm_source=test")!
        let normalized = URLNormalizer.normalize(url)
        let bytes = Data(normalized.utf8)
        let hash = CaptureFingerprint.contentHash(for: url)
        #expect(hash == CaptureFingerprint.contentHash(for: bytes))
        let link = SharedCapture(
            source: CaptureSource(kind: .link, contentHash: hash, url: normalized))
        let incoming = SharedCapture(
            source: CaptureSource(
                kind: kind, contentHash: CaptureFingerprint.contentHash(for: bytes),
                selection: kind == .text ? normalized : nil,
                blob: kind == .image ? try client.blobs.put(bytes) : nil))
        try verifyDistinct(link, incoming, client: client, server: fixture.server)
    }

    @Test func imagesWithDifferentBlobsDoNotAlias() throws {
        let fixture = try DeduplicationFixture()
        defer { fixture.clean() }
        let client = try fixture.client()
        let first = SharedCapture(
            source: CaptureSource(
                kind: .image, contentHash: "shared fingerprint",
                blob: try client.blobs.put(Data("first image".utf8))))
        let second = SharedCapture(
            source: CaptureSource(
                kind: .image, contentHash: "shared fingerprint",
                blob: try client.blobs.put(Data("second image".utf8))))
        try verifyDistinct(first, second, client: client, server: fixture.server)
    }

    @Test func compatibleImagesStillDeduplicate() throws {
        let fixture = try DeduplicationFixture()
        defer { fixture.clean() }
        let client = try fixture.client()
        let blob = try client.blobs.put(Data("same image".utf8))
        let source = CaptureSource(kind: .image, contentHash: blob.digest, blob: blob)
        let first = SharedCapture(source: source)
        let second = SharedCapture(source: source)
        try client.enqueue(captureID: first.id, mutation: .create(first))
        try client.enqueue(captureID: second.id, mutation: .create(second))
        #expect(try client.captures().map(\.id) == [first.id])
        #expect(try client.captures().first?.seenCount == 2)
        let receipts = try client.push(to: fixture.server)
        #expect(receipts.allSatisfy { $0.outcome == .accepted && $0.capture?.id == first.id })
        #expect(try fixture.server.baseline().captures.first?.seenCount == 2)
        #expect(try client.captures().first?.seenCount == 2)
    }

    @Test func incompatibleTombstoneDoesNotRejectNewCapture() throws {
        let fixture = try DeduplicationFixture()
        defer { fixture.clean() }
        let client = try fixture.client()
        let link = SharedCapture(
            source: CaptureSource(
                kind: .link, contentHash: "shared hash", url: "https://example.com"))
        try client.enqueue(captureID: link.id, mutation: .create(link))
        try client.enqueue(captureID: link.id, mutation: .delete)
        try client.push(to: fixture.server)
        let text = SharedCapture(
            source: CaptureSource(kind: .text, contentHash: "shared hash", selection: "text"))
        try client.enqueue(captureID: text.id, mutation: .create(text))
        #expect(try client.captures().map(\.id) == [text.id])
        #expect(try client.push(to: fixture.server).first?.outcome == .accepted)
        #expect(try client.rejectedWork().isEmpty)
        let captures = try fixture.server.baseline().captures
        #expect(captures.count == 2)
        #expect(captures.first { $0.id == link.id }?.deleted == true)
        #expect(captures.first { $0.id == text.id }?.deleted == false)
    }

    @Test func snapshotPreservesDistinctSourcesWithEqualHashes() throws {
        let fixture = try DeduplicationFixture()
        defer { fixture.clean() }
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let server = try SyncServer(
            databaseURL: fixture.root.appendingPathComponent("bound-server.sqlite"),
            blobDirectory: fixture.root.appendingPathComponent("bound-server-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        let link = SharedCapture(
            source: CaptureSource(
                kind: .link, contentHash: "shared hash", url: "https://example.com"))
        let text = SharedCapture(
            source: CaptureSource(kind: .text, contentHash: "shared hash", selection: "text"))
        let firstBlob = try server.blobs.put(Data("first image".utf8))
        let secondBlob = try server.blobs.put(Data("second image".utf8))
        let firstImage = SharedCapture(
            source: CaptureSource(kind: .image, contentHash: "shared hash", blob: firstBlob))
        let secondImage = SharedCapture(
            source: CaptureSource(kind: .image, contentHash: "shared hash", blob: secondBlob))
        let captures = [link, text, firstImage, secondImage]
        let snapshot = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: binding, sourceDeviceID: UUID(), captures: captures)
        let preview = try server.previewContentSnapshotImport(snapshot)
        #expect(preview.items.allSatisfy { $0.disposition == .insert })
        _ = try server.importContentSnapshot(snapshot, preview: preview)
        #expect(Set(try server.baseline().captures.map(\.id)) == Set(captures.map(\.id)))
        let repeated = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: binding, sourceDeviceID: UUID(), captures: captures)
        #expect(
            try server.previewContentSnapshotImport(repeated).items.allSatisfy {
                $0.disposition == .merge
            })
        let collision = SharedCapture(id: link.id, source: text.source)
        let invalid = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: binding, sourceDeviceID: UUID(),
            captures: [collision])
        #expect(throws: ContentSnapshotImportError.identityCollision) {
            try server.previewContentSnapshotImport(invalid)
        }
    }

    @Test(arguments: [Int.max - 1, Int.max])
    func optimisticRecaptureAndDuplicateCountsSaturate(_ count: Int) throws {
        let fixture = try DeduplicationFixture()
        defer { fixture.clean() }
        let writer = try SyncDatabase.open(
            at: fixture.root.appendingPathComponent("counter.sqlite"))
        let client = try SyncClient(
            writer: writer,
            blobs: BlobStore(directory: fixture.root.appendingPathComponent("counter-blobs")))
        let source = CaptureSource(
            kind: .text, contentHash: "counter hash", selection: "counter text")
        var original = SharedCapture(source: source)
        original.seenCount = count
        original.revision = 1
        try writer.write { try SyncDatabase.save($0, original) }
        for _ in 0..<2 {
            try client.enqueue(captureID: original.id, mutation: .recapture)
            #expect(try client.captures().first?.seenCount == Int.max)
        }
        let duplicate = SharedCapture(source: source)
        try client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        #expect(try client.captures().count == 1)
        #expect(try client.captures().first?.id == original.id)
        #expect(try client.captures().first?.seenCount == Int.max)
    }

    private func verifyDistinct(
        _ first: SharedCapture, _ second: SharedCapture, client: SyncClient, server: SyncServer
    ) throws {
        try client.enqueue(captureID: first.id, mutation: .create(first))
        try client.enqueue(captureID: second.id, mutation: .create(second))
        #expect(Set(try client.captures().map(\.id)) == [first.id, second.id])
        #expect(try client.captures().allSatisfy { $0.seenCount == 1 })
        let receipts = try client.push(to: server)
        #expect(receipts.map { $0.capture?.id } == [first.id, second.id])
        #expect(receipts.allSatisfy { $0.outcome == .accepted })
        let records = try server.baseline().captures
        #expect(records.count == 2)
        #expect(records.first { $0.id == first.id }?.source == first.source)
        #expect(records.first { $0.id == second.id }?.source == second.source)
        #expect(records.allSatisfy { $0.seenCount == 1 })
        #expect(Set(try client.captures().map(\.id)) == [first.id, second.id])
    }
}

private struct DeduplicationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("capd-dedup-\(UUID())")
    let server: SyncServer

    init() throws {
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-blobs"))
    }

    func client() throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("client.sqlite"),
            blobDirectory: root.appendingPathComponent("client-blobs"))
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
