import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CapdWebsiteIcons

struct WebsiteIconCacheTests {
    @Test(arguments: [Duration.zero, .seconds(6)])
    func sameOriginWaitersHaveAAdmissionLimit(resumeDelay: Duration) async throws {
        let bytes = try png()
        let identity = key(bytes)
        let gate = Gate()
        let deadline = Deadline()
        let refusals = Refusals()
        let cache = WebsiteIconCache(
            load: { _ in await gate.read() }, waitForDeadline: { try await deadline.wait() })
        let requests = (0..<100).map { _ in
            Task {
                let image = await cache.image(for: identity)
                if image == nil { await refusals.record() }
                return image
            }
        }
        await gate.waitForReads(1)
        await waitForAdmissions(100, cache: cache, refusals: refusals)
        try await Task.sleep(for: resumeDelay)
        #expect(await cache.pendingWaiters == 64)
        #expect(await refusals.count == 36)
        await gate.finish(bytes)
        var images = 0
        for request in requests { if await request.value != nil { images += 1 } }
        #expect(images == 64)
        #expect(await gate.readCount == 1)
    }

    @Test(arguments: [Duration.zero, .seconds(6)])
    func allOriginsShareAnAggregateWaiterLimit(resumeDelay: Duration) async throws {
        let bytes = try png()
        let gate = Gate()
        let refusals = Refusals()
        let deadline = Deadline()
        let cache = WebsiteIconCache(
            load: { _ in await gate.read() }, waitForDeadline: { try await deadline.wait() })
        let requests = (0..<1024).map { index in
            let identity = key(bytes, revision: Int64(index % 16 + 1))
            return Task {
                let image = await cache.image(for: identity)
                if image == nil { await refusals.record() }
                return image
            }
        }
        await gate.waitForReads(2)
        await waitForAdmissions(1024, cache: cache, refusals: refusals)
        try await Task.sleep(for: resumeDelay)
        #expect(await cache.pendingWaiters == 512)
        #expect(await refusals.count == 512)
        await cache.reset()
        for request in requests { #expect(await request.value == nil) }
        #expect(await gate.readCount == 2)
        await gate.finish(bytes)
    }
    @Test(arguments: ["digest", "malformed", "version", "bytes", "dimensions"])
    func refusesInvalidLocalAssets(problem: String) async throws {
        var data = try png()
        if problem == "malformed" { data = Data("not an image".utf8) }
        if problem == "bytes" { data.append(Data(count: WebsiteIconImage.byteLimit + 1)) }
        if problem == "dimensions" { data = try png(width: 65) }
        let identity = key(
            data, version: problem == "version" ? 2 : 1,
            digest: problem == "digest" ? String(repeating: "0", count: 64) : nil)
        let bytes = data
        let cache = WebsiteIconCache { _ in bytes }
        #expect(await cache.image(for: identity) == nil)
    }

    @Test func offlineLoadsAreCachedAndScopeAndRevisionAreDistinct() async throws {
        let bytes = try png()
        let first = key(bytes)
        let revised = key(bytes, revision: 2)
        let otherLibrary = key(bytes, library: "other")
        let otherGeneration = key(bytes, generation: UUID())
        let loads = Loads(bytes: bytes)
        let cache = WebsiteIconCache { identity in await loads.read(identity) }
        for identity in [first, first, revised, otherLibrary, otherGeneration] {
            #expect(await cache.image(for: identity)?.image.width == 64)
        }
        #expect(await loads.identities == [first, revised, otherLibrary, otherGeneration])
        await cache.reset()
        #expect(await cache.image(for: first) != nil)
        #expect(await loads.identities.count == 5)
    }

    @Test(arguments: [Duration.zero, .seconds(6)])
    func cancellingOneRowPreservesTheOtherWaiter(resumeDelay: Duration) async throws {
        let bytes = try png()
        let identity = key(bytes)
        let gate = Gate()
        let deadline = Deadline()
        let cache = WebsiteIconCache(
            load: { _ in await gate.read() }, waitForDeadline: { try await deadline.wait() })
        let first = Task { await cache.image(for: identity) }
        await gate.waitForReads(1)
        let second = Task { await cache.image(for: identity) }
        while await cache.pendingWaiters < 2 { await Task.yield() }
        try await Task.sleep(for: resumeDelay)
        first.cancel()
        #expect(await first.value == nil)
        await gate.finish(bytes)
        #expect(await second.value != nil)
        #expect(await gate.readCount == 1)
    }

    @Test func resetRejectsLateLoadsAndKeepsLocalWorkBounded() async throws {
        let bytes = try png()
        let gate = Gate()
        let deadline = Deadline()
        let refusals = Refusals()
        let cache = WebsiteIconCache(
            load: { _ in await gate.read() }, waitForDeadline: { try await deadline.wait() })
        let attempts = (0..<20).map { index in
            let identity = key(bytes, revision: Int64(index + 1))
            return Task {
                let image = await cache.image(for: identity)
                if image == nil { await refusals.record() }
                return image
            }
        }
        await gate.waitForReads(2)
        await waitForAdmissions(20, cache: cache, refusals: refusals)
        #expect(await cache.pendingWaiters == 16)
        #expect(await gate.readCount == 2)
        await cache.reset()
        for attempt in attempts { #expect(await attempt.value == nil) }
        let fresh = key(bytes, generation: UUID())
        let next = Task { await cache.image(for: fresh) }
        while await cache.pendingWaiters < 1 { await Task.yield() }
        #expect(await cache.activeLoads == 2)
        #expect(await gate.readCount == 2)
        await gate.finish(bytes)
        await gate.waitForReads(3)
        await gate.finish(bytes)
        #expect(await next.value != nil)
    }

    @Test func realFiveSecondDeadlineReleasesWaitersAndRetainsHungWorkers() async throws {
        let bytes = try png()
        let gate = Gate()
        let cache = WebsiteIconCache { _ in await gate.read() }
        let start = ContinuousClock.now
        let requests = (1...3).map { revision in
            Task { await cache.image(for: key(bytes, revision: Int64(revision))) }
        }
        await gate.waitForReads(2)
        for request in requests { #expect(await request.value == nil) }
        #expect(start.duration(to: .now) >= .seconds(5))
        #expect(await cache.pendingWaiters == 0)
        #expect(await cache.activeLoads == 2)
        #expect(await gate.readCount == 2)
        await gate.open(bytes)
    }

    @Test func controlledDeadlineReleasesExactlyItsPendingJob() async throws {
        let bytes = try png()
        let gate = Gate()
        let deadline = Deadline()
        let cache = WebsiteIconCache(
            load: { _ in await gate.read() }, waitForDeadline: { try await deadline.wait() })
        let request = Task { await cache.image(for: key(bytes)) }
        await gate.waitForReads(1)
        await deadline.waitUntilStarted()
        await deadline.fire()
        #expect(await request.value == nil)
        #expect(await cache.pendingWaiters == 0)
        #expect(await cache.activeLoads == 1)
        await gate.open(bytes)
        #expect(await cache.image(for: key(bytes)) != nil)
        #expect(await gate.readCount == 2)
    }
}

private func waitForAdmissions(_ count: Int, cache: WebsiteIconCache, refusals: Refusals) async {
    while await cache.pendingWaiters + refusals.count < count { await Task.yield() }
}

private actor Deadline {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    func waitUntilStarted() async { while waiters.isEmpty { await Task.yield() } }
    func fire() {
        let pending = waiters.values
        waiters = [:]
        for waiter in pending { waiter.resume() }
    }
}

private actor Refusals {
    var count = 0
    func record() { count += 1 }
}

private actor Loads {
    let bytes: Data
    var identities: [WebsiteIconIdentity] = []
    init(bytes: Data) { self.bytes = bytes }
    func read(_ identity: WebsiteIconIdentity) -> Data {
        identities.append(identity)
        return bytes
    }
}

private actor Gate {
    var readCount = 0
    private var opened: Data?
    private var readers: [CheckedContinuation<Data?, Never>] = []
    func read() async -> Data? {
        readCount += 1
        if let opened { return opened }
        return await withCheckedContinuation { readers.append($0) }
    }
    func waitForReads(_ count: Int) async {
        while readCount < count { await Task.yield() }
    }
    func finish(_ bytes: Data) {
        let pending = readers
        readers = []
        for reader in pending { reader.resume(returning: bytes) }
    }
    func open(_ bytes: Data) {
        opened = bytes
        finish(bytes)
    }
}

private func key(
    _ bytes: Data, library: String = "synthetic", generation: UUID = defaultGeneration,
    revision: Int64 = 1, version: Int = 1, digest: String? = nil
) -> WebsiteIconIdentity {
    .init(
        library: library, generation: generation, originID: String(repeating: "a", count: 64),
        revision: revision, normalizerVersion: version,
        digest: digest ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
}

private let defaultGeneration = UUID()

private func png(width: Int = 64) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 64))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}
