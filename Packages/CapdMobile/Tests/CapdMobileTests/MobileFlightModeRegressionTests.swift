import CapdSync
import Foundation
import Testing

@testable import CapdMobile

@Test func coordinatorRunsSyncAfterAnOverlappingRefresh() async throws {
    let fixture = try FlightModeFixture(pause: .availability)
    defer { fixture.clean() }
    let capture = MobileCapture(
        kind: .text, title: "Queued observation", selection: "Synthetic refresh-first content")
    try fixture.store.save(capture)
    let queued = try fixture.store.pending()
    let first = Task { try await fixture.coordinator.refresh() }
    await fixture.adapter.waitUntilPaused()
    let started = FlightCallerStart()
    let second = Task {
        await started.signal()
        return try await fixture.coordinator.sync()
    }
    await started.wait()
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.remote.operations().isEmpty)
    #expect(fixture.remote.cursors().isEmpty)
    #expect(try fixture.store.pending() == queued)
    await fixture.adapter.release()
    try await first.value
    #expect(try await second.value == .sent(1, rejected: 0))
    #expect(fixture.remote.operations() == queued)
    #expect(fixture.remote.cursors() == [0, 0, 0, 0, 1])
    #expect(try fixture.store.pending().isEmpty)
    #expect(try fixture.store.capture(id: capture.id)?.selection == capture.selection)
    #expect(fixture.remote.maximumConcurrent() == 1)
}

@Test func coordinatorRunsPullOnlyRefreshAfterAnOverlappingSync() async throws {
    let fixture = try FlightModeFixture(pause: .postPushPull)
    defer { fixture.clean() }
    try fixture.store.save(
        MobileCapture(kind: .text, title: "First observation", selection: "Synthetic first upload"))
    let uploaded = try fixture.store.pending()
    let first = Task { try await fixture.coordinator.sync() }
    await fixture.remote.waitUntilPaused()
    let retained = MobileCapture(
        kind: .text, title: "Later observation", selection: "Synthetic content after the first push"
    )
    try fixture.store.save(retained)
    let queued = try fixture.store.pending()
    let started = FlightCallerStart()
    let second = Task {
        await started.signal()
        try await fixture.coordinator.refresh()
    }
    await started.wait()
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.remote.operations() == uploaded)
    #expect(fixture.remote.cursors() == [0, 0])
    fixture.remote.release()
    #expect(try await first.value == .sent(1, rejected: 0))
    try await second.value
    #expect(fixture.remote.operations() == uploaded)
    #expect(fixture.remote.cursors() == [0, 0, 1, 1, 1])
    #expect(try fixture.store.pending() == queued)
    #expect(try fixture.store.capture(id: retained.id)?.selection == retained.selection)
    #expect(fixture.remote.maximumConcurrent() == 1)
}

@Test(arguments: [true, false])
func coordinatorCoalescesOverlappingCallsWithTheSameMode(pullOnly: Bool) async throws {
    let fixture = try FlightModeFixture(pause: .availability)
    defer { fixture.clean() }
    try fixture.store.save(
        MobileCapture(
            kind: .text, title: "Shared observation", selection: "Synthetic shared flight"))
    let queued = try fixture.store.pending()
    let first = Task { try await fixture.run(pullOnly: pullOnly) }
    await fixture.adapter.waitUntilPaused()
    let started = FlightCallerStart()
    let second = Task {
        await started.signal()
        return try await fixture.run(pullOnly: pullOnly)
    }
    await started.wait()
    for _ in 0..<20 { await Task.yield() }
    #expect(await fixture.adapter.count() == 1)
    #expect(fixture.remote.operations().isEmpty)
    await fixture.adapter.release()
    let expected = SyncResult.sent(pullOnly ? 0 : 1, rejected: 0)
    #expect(try await first.value == expected)
    #expect(try await second.value == expected)
    #expect(await fixture.adapter.count() == 1)
    #expect(fixture.remote.operations() == (pullOnly ? [] : queued))
    #expect(fixture.remote.cursors() == (pullOnly ? [0, 0] : [0, 0, 1]))
    #expect(try fixture.store.pending() == (pullOnly ? queued : []))
    #expect(fixture.remote.maximumConcurrent() == 1)
}

@Test func coordinatorRefreshDoesNotInheritAnOverlappingPushFailure() async throws {
    let fixture = try FlightModeFixture(pause: .failedApply)
    defer { fixture.clean() }
    let retained = MobileCapture(
        kind: .text, title: "Retained observation", selection: "Synthetic unacknowledged content")
    try fixture.store.save(retained)
    let queued = try fixture.store.pending()
    let first = Task { try await fixture.coordinator.sync() }
    await fixture.remote.waitUntilPaused()
    let started = FlightCallerStart()
    let second = Task {
        await started.signal()
        try await fixture.coordinator.refresh()
    }
    await started.wait()
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.remote.operations() == queued)
    #expect(try fixture.store.pending() == queued)
    fixture.remote.release()
    await #expect(throws: SyncError.acknowledgementLost) { try await first.value }
    try await second.value
    #expect(fixture.remote.cursors() == [0, 0, 0])
    #expect(fixture.remote.operations() == queued)
    #expect(try fixture.store.pending() == queued)
    #expect(try fixture.store.capture(id: retained.id)?.selection == retained.selection)
    try await fixture.coordinator.refresh()
    #expect(fixture.remote.cursors() == [0, 0, 0, 0, 0])
    #expect(fixture.remote.operations() == queued)
    #expect(try fixture.store.pending() == queued)
    #expect(fixture.remote.maximumConcurrent() == 1)
}

private enum FlightPause { case availability, postPushPull, failedApply }

private struct FlightModeFixture: Sendable {
    let root: URL
    let store: MobileStore
    let remote: FlightModeTransport
    let adapter: FlightModeAdapter
    let coordinator: MobileSyncCoordinator

    init(pause: FlightPause) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-flight-mode-\(UUID())")
        store = try MobileStore(url: root.appendingPathComponent("mobile.sqlite"))
        let server = try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-blobs"))
        remote = FlightModeTransport(server: server, pause: pause)
        adapter = FlightModeAdapter(remote: remote, pauseFirst: pause == .availability)
        coordinator = MobileSyncCoordinator(store: store, adapter: adapter)
    }

    func run(pullOnly: Bool) async throws -> SyncResult {
        if pullOnly {
            try await coordinator.refresh()
            return .sent(0, rejected: 0)
        }
        return try await coordinator.sync()
    }

    func clean() {
        remote.release()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor FlightCallerStart {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        started = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !started else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor FlightModeAdapter: MobileSyncAdapter {
    private let remote: FlightModeTransport
    private let pauseFirst: Bool
    private var calls = 0
    private var paused = false
    private var resumed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    init(remote: FlightModeTransport, pauseFirst: Bool) {
        self.remote = remote
        self.pauseFirst = pauseFirst
    }

    func availability() async -> SyncAvailability {
        calls += 1
        if pauseFirst, calls == 1, !resumed {
            paused = true
            waiter?.resume()
            waiter = nil
            await withCheckedContinuation { continuation = $0 }
        }
        return .ready
    }

    func transport() async -> (any SyncTransport)? { remote }
    func count() -> Int { calls }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}

private final class FlightModeTransport: SyncTransport, @unchecked Sendable {
    private let server: SyncServer
    private let pause: FlightPause
    private let gate = FlightBlockingGate()
    private let lock = NSLock()
    private var sent: [SyncOperation] = []
    private var changeCursors: [Int64] = []
    private var paused = false
    private var active = 0
    private var maximum = 0

    init(server: SyncServer, pause: FlightPause) {
        self.server = server
        self.pause = pause
    }

    func operations() -> [SyncOperation] { lock.withLock { sent } }
    func cursors() -> [Int64] { lock.withLock { changeCursors } }
    func maximumConcurrent() -> Int { lock.withLock { maximum } }
    func waitUntilPaused() async { await gate.waitUntilPaused() }
    func release() { gate.release() }

    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        begin()
        defer { end() }
        lock.withLock { sent.append(operation) }
        if pause == .failedApply {
            try gate.pause()
            throw SyncError.acknowledgementLost
        }
        return try server.apply(operation)
    }

    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        begin()
        defer { end() }
        let shouldPause = lock.withLock {
            changeCursors.append(cursor)
            guard pause == .postPushPull, !sent.isEmpty, !paused else { return false }
            paused = true
            return true
        }
        if shouldPause { try gate.pause() }
        return try server.changes(after: cursor, limit: limit)
    }

    func baseline() throws -> Baseline { try server.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try server.download(blob) }

    private func begin() {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
    }

    private func end() { lock.withLock { active -= 1 } }
}

private final class FlightBlockingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var paused = false
    private var waiter: CheckedContinuation<Void, Never>?

    func pause() throws {
        lock.withLock {
            paused = true
            waiter?.resume()
            waiter = nil
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw SyncError.transportDisconnected
        }
    }

    func waitUntilPaused() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if paused { continuation.resume() } else { waiter = continuation }
            }
        }
    }

    func release() { semaphore.signal() }
}
