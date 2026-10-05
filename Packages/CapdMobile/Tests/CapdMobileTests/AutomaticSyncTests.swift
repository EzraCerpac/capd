import CapdSync
import Foundation
import Testing

@testable import CapdMobile

private actor ManualSyncClock: SyncSchedulerClock {
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
        let ready = sleepers.filter { $0.value.0 <= date }
        for (id, entry) in ready {
            sleepers.removeValue(forKey: id)
            entry.1.resume()
        }
    }
    func count() -> Int { sleepers.count }
    func sleeperID() -> UUID? { sleepers.count == 1 ? sleepers.keys.first : nil }
    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
    }
}

private struct AutoFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("capd-auto-\(UUID())")
    var url: URL { root.appendingPathComponent("mobile.sqlite") }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func server() throws -> SyncServer {
        try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-blobs"))
    }
}

private final class AutoTransport: SyncTransport, @unchecked Sendable {
    let server: SyncServer
    private let lock = NSLock()
    private var available = true
    private var drop = false
    private var sent: [SyncOperation] = []
    private var running = 0
    private var maximum = 0
    var onApply: (@Sendable () throws -> Void)?
    init(_ server: SyncServer) { self.server = server }
    func setAvailable(_ value: Bool) { lock.withLock { available = value } }
    func dropNext() { lock.withLock { drop = true } }
    func operations() -> [SyncOperation] { lock.withLock { sent } }
    func maximumConcurrent() -> Int { lock.withLock { maximum } }
    private func check() throws {
        if !lock.withLock({ available }) { throw SyncError.transportDisconnected }
    }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        try check()
        lock.withLock {
            sent.append(operation)
            running += 1
            maximum = max(maximum, running)
        }
        defer { lock.withLock { running -= 1 } }
        let receipt = try server.apply(operation)
        try onApply?()
        let lost = lock.withLock {
            let result = drop
            drop = false
            return result
        }
        if lost { throw SyncError.acknowledgementLost }
        return receipt
    }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try check()
        return try server.changes(after: cursor, limit: limit)
    }
    func baseline() throws -> Baseline {
        try check()
        return try server.baseline()
    }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try check()
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data {
        try check()
        return try server.download(blob)
    }
}

private struct ReadyAutoAdapter: MobileSyncAdapter {
    let remote: any SyncTransport
    func availability() async -> SyncAvailability { .ready }
    func transport() async -> (any SyncTransport)? { remote }
}

private func eventually(_ condition: @escaping () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Automatic sync condition did not become true")
}

private func source(_ text: String) throws -> MobileCapture {
    try CaptureInput.make(text: text, isLink: false)
}

@Test func automaticDebounceBatchesLocalChangesAndPollsRemoteWhileIdle() async throws {
    let f = AutoFixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.url)
    let server = try f.server()
    let remote = AutoTransport(server)
    let clock = ManualSyncClock()
    let controller = AutomaticSyncController(
        store: store, adapter: ReadyAutoAdapter(remote: remote), clock: clock, jitter: { 1 })
    await controller.foreground()
    try await eventually {
        let state = await controller.currentState()
        let count = await clock.count()
        return state.lastSuccessfulSync != nil && count == 1
    }
    let pollSleeper = try #require(await clock.sleeperID())
    try store.save(source("Debounced first"))
    await controller.localChange()
    try await eventually {
        let sleeper = await clock.sleeperID()
        return sleeper != nil && sleeper != pollSleeper
    }
    let firstDebounceSleeper = try #require(await clock.sleeperID())
    try store.save(source("Debounced second"))
    await controller.localChange()
    try await eventually {
        let sleeper = await clock.sleeperID()
        return sleeper != nil && sleeper != firstDebounceSleeper
    }
    await clock.advance(0.3)
    #expect(remote.operations().isEmpty)
    await clock.advance(0.1)
    try await eventually { try store.pending().isEmpty }
    #expect(remote.operations().count == 2)
    #expect(remote.maximumConcurrent() == 1)
    let other = try SyncClient(
        databaseURL: f.root.appendingPathComponent("mac.sqlite"),
        blobDirectory: f.root.appendingPathComponent("mac-blobs"))
    let incoming = SharedCapture(
        source: CaptureSource(
            kind: .text, title: "Remote idle arrival", selection: "Source from another device"))
    try other.enqueue(captureID: incoming.id, mutation: .create(incoming))
    try other.push(to: server)
    try await eventually { await clock.count() == 1 }
    await clock.advance(30)
    try await eventually { try store.capture(id: incoming.id) != nil }
    await controller.suspend()
}

@Test func automaticRetryOfLostAckKeepsExactOperationAndDoesNotRepeatSideEffects() async throws {
    let f = AutoFixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.url)
    let server = try f.server()
    let remote = AutoTransport(server)
    remote.dropNext()
    let clock = ManualSyncClock()
    let capture = try source("Lost acknowledgement")
    try store.save(capture)
    let original = try store.pending()
    let controller = AutomaticSyncController(
        store: store, adapter: ReadyAutoAdapter(remote: remote), clock: clock, jitter: { 1 })
    await controller.foreground()
    try await eventually {
        let state = await controller.currentState()
        let count = await clock.count()
        return state.phase == .retrying && count == 1
    }
    #expect(try store.pending() == original)
    #expect(try server.baseline().captures.first?.seenCount == 1)
    await clock.advance(1)
    try await eventually { try store.pending().isEmpty }
    #expect(remote.operations() == [original[0], original[0]])
    #expect(try server.changes(after: 0).changes.count == 1)
    try await eventually { await controller.currentState().lastSuccessfulSync != nil }
    await controller.suspend()
}

@Test func automaticDrainsShareWriteQueuedDuringInflightBatchWithoutAnotherTrigger() async throws {
    let f = AutoFixture()
    defer { f.clean() }
    let app = try MobileStore(url: f.url)
    let share = try MobileStore(url: f.url)
    let server = try f.server()
    let remote = AutoTransport(server)
    let inserted = NSLock()
    nonisolated(unsafe) var didInsert = false
    remote.onApply = {
        let first = inserted.withLock {
            if didInsert { return false }
            didInsert = true
            return true
        }
        if first { try share.save(source("Shared during automatic batch")) }
    }
    try app.save(source("First automatic capture"))
    let controller = AutomaticSyncController(
        store: app, adapter: ReadyAutoAdapter(remote: remote), jitter: { 1 })
    await controller.foreground()
    try await eventually { try app.pending().isEmpty && server.baseline().captures.count == 2 }
    #expect(remote.operations().map(\.sequence) == [1, 2])
    #expect(remote.maximumConcurrent() == 1)
    await controller.suspend()
}

@Test func cancellationSuspensionAndReconnectRetainDurableWork() async throws {
    let f = AutoFixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.url)
    let server = try f.server()
    let remote = AutoTransport(server)
    let clock = ManualSyncClock()
    let controller = AutomaticSyncController(
        store: store, adapter: ReadyAutoAdapter(remote: remote), clock: clock, jitter: { 1 })
    await controller.foreground()
    try await eventually {
        let state = await controller.currentState()
        let count = await clock.count()
        return state.lastSuccessfulSync != nil && count == 1
    }
    try store.save(source("Suspended debounce"))
    await controller.localChange()
    let original = try store.pending()
    await controller.suspend()
    await clock.advance(60)
    #expect(remote.operations().isEmpty)
    #expect(try store.pending() == original)
    await controller.connectivityChanged(available: false)
    await controller.foreground()
    let disconnectedState = await controller.currentState()
    #expect(disconnectedState.phase == .offline || disconnectedState.phase == .paused)
    await controller.connectivityChanged(available: true)
    try await eventually { try store.pending().isEmpty }
    #expect(remote.operations().first == original.first)
    await controller.suspend()
}

@Test func unconfiguredDoesNotRetryOrPretendEmptyQueueMeansSuccess() async throws {
    let f = AutoFixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.url)
    let clock = ManualSyncClock()
    let controller = AutomaticSyncController(store: store, clock: clock)
    await controller.foreground()
    try await eventually { await controller.currentState().phase == .setupRequired }
    try store.save(source("Local unconfigured"))
    await controller.localChange()
    await clock.advance(3600)
    #expect(await clock.count() == 0)
    #expect(await controller.currentState().lastSuccessfulSync == nil)
    #expect(try store.pending().count == 1)
    await controller.suspend()
}

@Test func retryBackoffStopsAfterBoundAndReopenResumesSameOutbox() async throws {
    let f = AutoFixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.url)
    let server = try f.server()
    let remote = AutoTransport(server)
    remote.setAvailable(false)
    let clock = ManualSyncClock()
    try store.save(source("Offline retry"))
    let original = try store.pending()
    let policy = AutomaticSyncPolicy(maximumFailures: 3)
    let controller = AutomaticSyncController(
        store: store, adapter: ReadyAutoAdapter(remote: remote), clock: clock, policy: policy,
        jitter: { 1 })
    await controller.foreground()
    try await eventually {
        let state = await controller.currentState()
        let count = await clock.count()
        return state.consecutiveFailures == 1 && count == 1
    }
    await clock.advance(1)
    try await eventually {
        let state = await controller.currentState()
        let count = await clock.count()
        return state.consecutiveFailures == 2 && count == 1
    }
    await clock.advance(2)
    try await eventually { await controller.currentState().consecutiveFailures == 3 }
    #expect(await controller.currentState().phase == .attention)
    #expect(await clock.count() == 0)
    #expect(try store.pending() == original)
    await controller.suspend()
    let reopened = try MobileStore(url: f.url)
    remote.setAvailable(true)
    let fresh = AutomaticSyncController(store: reopened, adapter: ReadyAutoAdapter(remote: remote))
    await fresh.foreground()
    try await eventually { try reopened.pending().isEmpty }
    #expect(remote.operations().first == original.first)
    await fresh.suspend()
}

private actor PausedAvailability: MobileSyncAdapter {
    let remote: AutoTransport
    private var continuation: CheckedContinuation<Void, Never>?
    private var calls = 0
    init(_ remote: AutoTransport) { self.remote = remote }
    func availability() async -> SyncAvailability {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return .ready
    }
    func transport() async -> (any SyncTransport)? { remote }
    func count() -> Int { calls }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@Test func coordinatorCoalescesBeforeAvailabilityAwaitAndReturnsRealResult() async throws {
    let f = AutoFixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.url)
    let remote = AutoTransport(try f.server())
    try store.save(source("Coalesced availability"))
    let adapter = PausedAvailability(remote)
    let coordinator = MobileSyncCoordinator(store: store, adapter: adapter)
    let first = Task { try await coordinator.sync() }
    try await eventually { await adapter.count() == 1 }
    let second = Task { try await coordinator.sync() }
    for _ in 0..<20 { await Task.yield() }
    #expect(await adapter.count() == 1)
    await adapter.resume()
    #expect(try await first.value == .sent(1, rejected: 0))
    #expect(try await second.value == .sent(1, rejected: 0))
    #expect(remote.maximumConcurrent() == 1)
}

@Test func suspensionDuringCommittedRequestFinishesExactAckThenResumesWithoutOverlap() async throws
{
    let f = AutoFixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.url)
    let server = try f.server()
    let remote = AutoTransport(server)
    let gate = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    let lock = NSLock()
    nonisolated(unsafe) var first = true
    remote.onApply = {
        let pause = lock.withLock {
            let result = first
            first = false
            return result
        }
        if pause {
            started.signal()
            _ = gate.wait(timeout: .now() + 2)
        }
    }
    try store.save(source("Cancel first"))
    try store.save(source("Cancel second"))
    let original = try store.pending()
    let controller = AutomaticSyncController(
        store: store, adapter: ReadyAutoAdapter(remote: remote))
    await controller.foreground()
    try await eventually { try server.baseline().captures.count == 1 }
    await controller.suspend()
    await controller.foreground()
    gate.signal()
    try await eventually { try store.pending().isEmpty && remote.operations().count == 2 }
    #expect(remote.operations().map(\.id) == original.map(\.id))
    #expect(remote.maximumConcurrent() == 1)
    #expect(try server.changes(after: 0).changes.count == 2)
    await controller.suspend()
}
