import Foundation
import Testing

@testable import CapdMobile
@testable import CapdSync

@Test func continuedRemoteFeedYieldsToExactQueuedPushAndResumesNextCycle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(url: root.appendingPathComponent("mobile.sqlite"))
    let server = try SyncServer(
        databaseURL: root.appendingPathComponent("authority.sqlite"),
        blobDirectory: root.appendingPathComponent("authority-blobs"))
    try store.save(CaptureInput.make(text: "Durable queued source", isLink: false))
    let original = try store.pending()
    let transport = ContinuousReviewFeed(server: server)
    let coordinator = MobileSyncCoordinator(
        store: store, adapter: ContinuousReviewAdapter(remote: transport))
    #expect(try await coordinator.sync() == .sent(1, rejected: 0))
    #expect(transport.applied == original)
    #expect(transport.pushPageCounts == [MobileStore.pullPageBudget])
    #expect(transport.calls == MobileStore.pullPageBudget * 2)
    #expect(try store.pending().isEmpty)
    #expect(
        try store.capture(id: transport.captureID)?.revision
            == Int64(MobileStore.pullPageBudget * 2 * 100))
    #expect(try await coordinator.sync() == .sent(0, rejected: 0))
    #expect(transport.calls == MobileStore.pullPageBudget * 4)
    #expect(transport.applied == original)
    #expect(
        try store.capture(id: transport.captureID)?.revision
            == Int64(MobileStore.pullPageBudget * 4 * 100))
}

private struct ContinuousReviewAdapter: MobileSyncAdapter {
    let remote: ContinuousReviewFeed
    func availability() -> SyncAvailability { .ready }
    func transport() -> (any SyncTransport)? { remote }
}

private final class ContinuousReviewFeed: SyncTransport, @unchecked Sendable {
    enum Failure: Error { case excessivePulls }
    let captureID: UUID
    private let sourceRecord: SharedCapture
    private let remoteDeviceID = UUID()
    private let server: SyncServer
    private let lock = NSLock()
    private var requests = 0
    private var operations: [SyncOperation] = []
    private var pageCounts: [Int] = []
    var calls: Int { lock.withLock { requests } }
    var applied: [SyncOperation] { lock.withLock { operations } }
    var pushPageCounts: [Int] { lock.withLock { pageCounts } }
    init(server: SyncServer) {
        let captureID = UUID()
        self.captureID = captureID
        self.sourceRecord = SharedCapture(
            id: captureID,
            source: CaptureSource(
                kind: .text, selection: "Continuously advancing remote source"))
        self.server = server
    }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        let calls = lock.withLock {
            requests += 1
            return requests
        }
        guard calls <= MobileStore.pullPageBudget * 4 else { throw Failure.excessivePulls }
        let changes = (1...limit).map { offset in
            let revision = cursor + Int64(offset)
            var capture = sourceRecord
            capture.revision = revision
            return FeedChange(
                cursor: revision, operationID: UUID(), deviceID: remoteDeviceID,
                sequence: revision, requestedCaptureID: captureID, capture: capture)
        }
        return FeedPage(cursor: cursor + Int64(limit), changes: changes)
    }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        lock.withLock {
            operations.append(operation)
            pageCounts.append(requests)
        }
        return try server.apply(operation)
    }
    func baseline() throws -> Baseline { try server.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try server.download(blob) }
}
