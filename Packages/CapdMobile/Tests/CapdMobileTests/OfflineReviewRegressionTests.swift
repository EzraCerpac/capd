import Foundation
import Testing

@testable import CapdMobile
@testable import CapdSync

@Suite("Synthetic mobile pull, capture budget and adapter recovery")
struct OfflineReviewRegressionTests {
    @Test(arguments: [100, 101])
    func pullsPastFormerPageLimitUntilEmpty(pages: Int) throws {
        let fixture = OfflineReviewFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        let transport = ReviewPagingTransport(pages: pages)
        try store.pull(from: transport)
        #expect(transport.calls == pages + 1)
        #expect(try store.capture(id: transport.captureID)?.revision == Int64(pages * 100))
    }

    @Test func rejectsOversizedUTF8PasteWithoutTruncating() {
        let text = String(repeating: "é", count: SyncHTTPHandler.maximumBodyBytes / 2 + 1)
        #expect(throws: CaptureValidationError.tooLarge) {
            try CaptureInput.make(text: text, isLink: false)
        }
    }

    @Test func encodedEnvelopeBudgetRollsBackProjectionOutboxAndSequence() throws {
        let fixture = OfflineReviewFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        let kept = try CaptureInput.make(text: "Kept before rejection", isLink: false)
        try store.save(kept)
        let pending = try store.pending()
        let escaped = String(repeating: "\u{0001}", count: SyncHTTPHandler.maximumBodyBytes / 6)
        let oversized = try CaptureInput.make(text: escaped, isLink: false)
        #expect(oversized.selection == escaped)
        #expect(throws: CaptureValidationError.tooLarge) { try store.save(oversized) }
        let reopened = try MobileStore(url: fixture.url)
        #expect(try reopened.pending() == pending)
        #expect(try reopened.capture(id: oversized.id) == nil)
        let next = try CaptureInput.make(text: "Kept after rejection", isLink: false)
        try reopened.save(next)
        #expect(try reopened.pending().map(\.sequence) == [1, 2])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for operation in try reopened.pending() {
            let envelope = SyncHTTPEnvelope(
                expectedServiceID: UUID(), expectedLibraryID: UUID(),
                expectedDeviceID: reopened.deviceID, action: .apply(operation))
            #expect(try encoder.encode(envelope).count <= SyncHTTPHandler.maximumBodyBytes)
        }
    }

    @Test func oversizedEditRollsBackWithoutBlockingLaterAnnotation() throws {
        let fixture = OfflineReviewFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        let kept = try CaptureInput.make(text: "Original source", isLink: false)
        try store.save(kept)
        let observed = try #require(try store.capture(id: kept.id))
        let pending = try store.pending()
        let note = String(repeating: "\u{0001}", count: SyncHTTPHandler.maximumBodyBytes / 6)
        #expect(throws: CaptureValidationError.tooLarge) {
            try store.update(observed, note: note, tags: ["rejected"])
        }
        let reopened = try MobileStore(url: fixture.url)
        #expect(try reopened.pending() == pending)
        #expect(try reopened.capture(id: kept.id) == observed)
        try reopened.update(id: kept.id, note: "Small annotation", tags: ["kept"])
        #expect(try reopened.pending().map(\.sequence) == [1, 2])
        #expect(try reopened.capture(id: kept.id)?.note == "Small annotation")
        #expect(try reopened.capture(id: kept.id)?.manualTags == ["kept"])
    }

    @Test(arguments: [false, true])
    func offlineAdapterRecoversWhileForegroundWithoutOtherTriggers(pendingLocalWork: Bool)
        async throws
    {
        let fixture = OfflineReviewFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        let server = try SyncServer(
            databaseURL: fixture.root.appendingPathComponent("authority.sqlite"),
            blobDirectory: fixture.root.appendingPathComponent("authority-blobs"))
        let incoming = SharedCapture(
            source: CaptureSource(kind: .text, selection: "Remote while adapter is offline"))
        _ = try server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: incoming.id, baseRevision: 0,
                mutation: .create(incoming)))
        if pendingLocalWork {
            try store.save(CaptureInput.make(text: "Durable local work", isLink: false))
        }
        let pending = try store.pending()
        let adapter = ReviewRecoveringAdapter(server: server)
        let clock = ReviewSyncClock()
        let controller = AutomaticSyncController(
            store: store, adapter: adapter, clock: clock,
            policy: AutomaticSyncPolicy(foregroundPullInterval: 1), jitter: { 1 })
        await controller.foreground()
        try await reviewEventually {
            let state = await controller.currentState()
            let count = await clock.count()
            return state.phase == .offline && count == 1
        }
        #expect(try store.pending() == pending)
        await adapter.becomeReady()
        await clock.advance(1)
        try await reviewEventually {
            let state = await controller.currentState()
            return try state.lastSuccessfulSync != nil && store.pending().isEmpty
                && store.capture(id: incoming.id) != nil
        }
        try await reviewEventually { await clock.count() == 1 }
        await controller.suspend()
        try await reviewEventually { await clock.count() == 0 }
        await clock.advance(1)
        #expect(await adapter.checkCount() == 2)
        #expect(await controller.currentState().phase == .paused)
    }
}

private struct OfflineReviewFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var url: URL { root.appendingPathComponent("mobile.sqlite") }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private final class ReviewPagingTransport: SyncTransport, @unchecked Sendable {
    let captureID = UUID()
    private let deviceID = UUID()
    private let pages: Int
    private let lock = NSLock()
    private var requests = 0
    var calls: Int { lock.withLock { requests } }
    init(pages: Int) { self.pages = pages }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        lock.withLock { requests += 1 }
        if cursor == Int64(pages * 100) { return FeedPage(cursor: cursor, changes: []) }
        let changes = (1...100).map { offset in
            let revision = cursor + Int64(offset)
            var capture = SharedCapture(
                id: captureID, source: CaptureSource(kind: .text, selection: "Paged remote source"))
            capture.revision = revision
            return FeedChange(
                cursor: revision, operationID: UUID(), deviceID: deviceID, sequence: revision,
                requestedCaptureID: captureID, capture: capture)
        }
        return FeedPage(cursor: cursor + 100, changes: changes)
    }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        throw SyncError.invalidOperation
    }
    func baseline() throws -> Baseline { throw SyncError.invalidOperation }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        throw SyncError.invalidOperation
    }
    func download(_ blob: BlobReference) throws -> Data { throw SyncError.invalidOperation }
}

private actor ReviewRecoveringAdapter: MobileSyncAdapter {
    let server: SyncServer
    private var ready = false
    private var checks = 0
    init(server: SyncServer) { self.server = server }
    func becomeReady() { ready = true }
    func checkCount() -> Int { checks }
    func availability() -> SyncAvailability {
        checks += 1
        return ready ? .ready : .offline
    }
    func transport() -> (any SyncTransport)? { server }
}

private actor ReviewSyncClock: SyncSchedulerClock {
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    private var sleepers: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
    func now() -> Date { date }
    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        if seconds <= 0 { return }
        let id = UUID()
        let deadline = date.addingTimeInterval(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = (deadline, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func advance(_ seconds: TimeInterval) {
        date.addTimeInterval(seconds)
        for (id, entry) in sleepers.filter({ $0.value.0 <= date }) {
            sleepers.removeValue(forKey: id)
            entry.1.resume()
        }
    }
    func count() -> Int { sleepers.count }
    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }
}

private func reviewEventually(_ condition: @escaping () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Mobile recovery condition did not become true")
}
