import AppKit
import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdAppUI
@testable import CapdKit

@MainActor
@Suite("Offline favicon store")
struct FaviconStoreTests {
    @Test(arguments: ["replacement", "new", "removed"])
    func anotherStoreRefreshesAnExistingConsumer(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        let app = try Store(paths: paths)
        let agent = try Store(paths: paths)
        let capture = try CaptureService(store: agent).ingest(
            CaptureRequest(url: "https://sqlite.org/first", fetchBody: false))
        try agent.setWebsiteIconsEnabled(true)
        let dark = try normalizedPNG(.black)
        let generator = WebsiteIconService(store: agent, fetch: { _ in .normalizedPNG(dark) })
        #expect(try await generator.processNext())
        let consumer = FaviconStore(store: app, scope: paths.databaseURL.path)
        #expect(
            try await eventually {
                consumer.favicon(forURL: "https://sqlite.org")?.needsLightBacking == true
            })

        let url: String
        switch change {
        case "replacement":
            url = "https://sqlite.org"
            let light = try normalizedPNG(.white)
            let record = try icon(url, bytes: light, revision: 2)
            let blobs = try BlobStore(
                directory: paths.assetsDirectory.appendingPathComponent("website-icons"))
            _ = try blobs.put(light)
            try agent.write { try Store.projectWebsiteIcon(in: $0, record: record) }
        case "new":
            url = "https://www.sqlite.org"
            _ = try CaptureService(store: agent).ingest(
                CaptureRequest(url: url + "/second", fetchBody: false))
            #expect(try await generator.processNext())
        default:
            url = "https://sqlite.org"
            _ = try agent.deleteCaptures(ids: [try #require(capture.capture.id)])
        }
        #expect(
            try await eventually {
                switch change {
                case "replacement": consumer.favicon(forURL: url)?.needsLightBacking == false
                case "new": consumer.favicon(forURL: url) != nil
                default: consumer.favicon(forURL: url) == nil
                }
            })
    }

    @Test func failedConfigurationReadRetriesAfterRestorationWithoutDatabaseWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        let bytes = try normalizedPNG(.black)
        let store = try await seededStore(paths: paths, bytes: bytes)
        let reader = FaviconRecordReader(store: store)
        let records = try #require(try await reader.changedRecords())
        #expect(try await reader.changedRecords() == nil)
        let consumer = FaviconStore(scope: "synthetic", records: records) { _ in bytes }
        let clock = RefreshClock()
        let task = consumer.startRefreshing(
            readRecords: { try await reader.changedRecords() }, wait: { try await clock.wait() })
        defer { task.cancel() }
        await clock.waitUntilSleeping(1)
        _ = consumer.favicon(forURL: "https://sqlite.org")
        await consumer.awaitPendingLoads()
        #expect(consumer.favicon(forURL: "https://sqlite.org") != nil)
        let configuration = MacSyncConfiguration.url(paths: paths)
        try Data("{}".utf8).write(to: configuration)
        await clock.advance()
        await clock.waitUntilSleeping(2)
        #expect(consumer.favicon(forURL: "https://sqlite.org") == nil)
        try FileManager.default.removeItem(at: configuration)
        await clock.advance()
        await clock.waitUntilSleeping(3)
        _ = consumer.favicon(forURL: "https://sqlite.org")
        await consumer.awaitPendingLoads()
        #expect(consumer.favicon(forURL: "https://sqlite.org") != nil)
        task.cancel()
        await task.value
    }

    @Test func replacingTheDatabaseFileRetiresItsPoolAndArtwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try normalizedPNG(.black)
        let paths = StoragePaths(root: root.appendingPathComponent("first"))
        let store = try await seededStore(paths: paths, bytes: bytes)
        let reader = FaviconRecordReader(store: store)
        let records = try #require(try await reader.changedRecords())
        let consumer = FaviconStore(scope: "first", records: records) { _ in bytes }
        let clock = RefreshClock()
        let task = consumer.startRefreshing(
            readRecords: { try await reader.changedRecords() }, wait: { try await clock.wait() })
        defer { task.cancel() }
        await clock.waitUntilSleeping(1)
        _ = consumer.favicon(forURL: "https://sqlite.org")
        await consumer.awaitPendingLoads()
        #expect(consumer.favicon(forURL: "https://sqlite.org") != nil)
        let other = try Store(paths: StoragePaths(root: root.appendingPathComponent("second")))
        try FileManager.default.moveItem(
            at: paths.databaseURL, to: root.appendingPathComponent("retired.sqlite"))
        try FileManager.default.copyItem(at: other.paths.databaseURL, to: paths.databaseURL)
        await clock.advance()
        await clock.waitUntilSleeping(2)
        #expect(consumer.favicon(forURL: "https://sqlite.org") == nil)
        await clock.advance()
        await clock.waitUntilSleeping(3)
        #expect(consumer.favicon(forURL: "https://sqlite.org") == nil)
        task.cancel()
        await task.value
    }

    @Test func aRetiredRefreshCannotReplaceNewerRecords() async throws {
        let dark = try png(.black)
        let light = try png(.white)
        let first = try icon("https://sqlite.org", bytes: dark)
        let second = try icon("https://sqlite.org", bytes: light, revision: 2)
        let consumer = FaviconStore(scope: "synthetic") { record in
            record.revision == 1 ? dark : light
        }
        let gate = RecordGate()
        let old = consumer.startRefreshing(readRecords: { await gate.read() })
        await gate.waitUntilStarted()
        let clock = RefreshClock()
        let current = consumer.startRefreshing(
            readRecords: { [second] },
            wait: {
                try await clock.wait()
            })
        defer { current.cancel() }
        await clock.waitUntilSleeping(1)
        await gate.finish([first])
        await old.value
        _ = consumer.favicon(forURL: "https://sqlite.org")
        await consumer.awaitPendingLoads()
        #expect(consumer.favicon(forURL: "https://sqlite.org")?.needsLightBacking == false)
        current.cancel()
        await current.value
    }

    @Test func releasingTheConsumerCancelsItsOnlyRefreshLoop() async throws {
        var consumer: FaviconStore? = FaviconStore(scope: "synthetic") { _ in nil }
        weak var released = consumer
        let clock = RefreshClock()
        let task = try #require(consumer).startRefreshing(
            readRecords: { [] },
            wait: {
                try await clock.wait()
            })
        await clock.waitUntilSleeping(1)
        consumer = nil
        #expect(released == nil)
        await task.value
        #expect(await clock.sleepCount == 1)
        #expect(await clock.cancellationCount == 1)
    }

    @Test func localPNGUsesExactHTTPSOriginAndPreservesWWW() async throws {
        let bytes = try png(.black)
        let record = try icon("https://www.sqlite.org", bytes: bytes)
        let reader = LocalReader(bytes)
        let store = FaviconStore(scope: "synthetic", records: [record]) { _ in await reader.read() }
        #expect(store.favicon(forURL: "https://www.sqlite.org/one?q=private") == nil)
        await store.awaitPendingLoads()
        #expect(store.favicon(forURL: "https://www.sqlite.org/two") != nil)
        #expect(store.favicon(forURL: "https://sqlite.org") == nil)
        #expect(store.favicon(forURL: "http://www.sqlite.org") == nil)
        #expect(store.favicon(forURL: "https://user@www.sqlite.org") == nil)
        #expect(await reader.calls == 1)
    }

    @Test func replacementTombstoneAndRestoreHideOldArtwork() async throws {
        let dark = try png(.black)
        let light = try png(.white)
        let first = try icon("https://sqlite.org", bytes: dark)
        let second = try icon("https://sqlite.org", bytes: light, revision: 2)
        let reader = LocalReader(dark)
        let store = FaviconStore(scope: "synthetic", records: [first]) { _ in await reader.read() }
        _ = store.favicon(forURL: "https://sqlite.org")
        await store.awaitPendingLoads()
        #expect(store.favicon(forURL: "https://sqlite.org")?.needsLightBacking == true)
        await reader.replace(light)
        store.replaceRecords([second])
        #expect(store.favicon(forURL: "https://sqlite.org") == nil)
        await store.awaitPendingLoads()
        #expect(store.favicon(forURL: "https://sqlite.org")?.needsLightBacking == false)
        store.replaceRecords([
            WebsiteIconRecord(
                origin: second.origin, revision: 3, deleted: true,
                content: second.content)
        ])
        #expect(store.favicon(forURL: "https://sqlite.org") == nil)
        store.replaceRecords([second])
        _ = store.favicon(forURL: "https://sqlite.org")
        await store.awaitPendingLoads()
        #expect(store.favicon(forURL: "https://sqlite.org") != nil)
    }

    @Test func deletionFencesALateLocalRead() async throws {
        let bytes = try png(.black)
        let record = try icon("https://sqlite.org", bytes: bytes)
        let gate = LocalGate()
        let store = FaviconStore(scope: "synthetic", records: [record]) { _ in await gate.read() }
        _ = store.favicon(forURL: "https://sqlite.org")
        await gate.waitUntilStarted()
        store.replaceRecords([])
        await gate.finish(bytes)
        for _ in 0..<100 { await Task.yield() }
        #expect(store.favicon(forURL: "https://sqlite.org") == nil)
    }

    @Test(arguments: ["missing", "corrupt", "digest", "oversize"])
    func unavailableOrInvalidBlobFallsBack(problem: String) async throws {
        let bytes = try png(.white)
        let record = try icon("https://sqlite.org", bytes: bytes)
        let result: Data? =
            switch problem {
            case "missing": nil
            case "corrupt": Data("not PNG".utf8)
            case "digest": try png(.black)
            default: Data(count: 262_145)
            }
        let store = FaviconStore(scope: "synthetic", records: [record]) { _ in result }
        _ = store.favicon(forURL: "https://sqlite.org")
        await store.awaitPendingLoads()
        #expect(store.favicon(forURL: "https://sqlite.org") == nil)
    }

    @Test func aDifferentLibraryCannotReuseThePreviousLibraryImage() async throws {
        let bytes = try png(.black)
        let record = try icon("https://sqlite.org", bytes: bytes)
        let first = FaviconStore(scope: "first", records: [record]) { _ in bytes }
        _ = first.favicon(forURL: "https://sqlite.org")
        await first.awaitPendingLoads()
        #expect(first.favicon(forURL: "https://sqlite.org") != nil)
        let second = FaviconStore(scope: "second", records: []) { _ in
            Issue.record("A library without an icon record must not load cached pixels")
            return bytes
        }
        #expect(second.favicon(forURL: "https://sqlite.org") == nil)
        await second.awaitPendingLoads()
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(60))
    while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    return condition()
}

@MainActor
private func seededStore(paths: StoragePaths, bytes: Data) async throws -> Store {
    let store = try Store(paths: paths)
    _ = try CaptureService(store: store).ingest(
        CaptureRequest(url: "https://sqlite.org/first", fetchBody: false))
    try store.setWebsiteIconsEnabled(true)
    #expect(
        try await WebsiteIconService(store: store, fetch: { _ in .normalizedPNG(bytes) })
            .processNext())
    return store
}

private actor RecordGate {
    private var reader: CheckedContinuation<[WebsiteIconRecord]?, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func read() async -> [WebsiteIconRecord]? {
        await withCheckedContinuation {
            reader = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        guard reader == nil else { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ records: [WebsiteIconRecord]) {
        reader?.resume(returning: records)
        reader = nil
    }
}

private actor RefreshClock {
    private var sleeper: CheckedContinuation<Void, any Error>?
    private var observer: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    var sleepCount = 0
    var cancellationCount = 0
    func wait() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sleeper = continuation
                sleepCount += 1
                if let observer, sleepCount >= observer.count {
                    observer.continuation.resume()
                    self.observer = nil
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    func waitUntilSleeping(_ count: Int) async {
        guard sleepCount < count else { return }
        await withCheckedContinuation { observer = (count, $0) }
    }
    func advance() {
        sleeper?.resume()
        sleeper = nil
    }
    private func cancel() {
        cancellationCount += 1
        sleeper?.resume(throwing: CancellationError())
        sleeper = nil
    }
}

@MainActor
private func normalizedPNG(_ color: NSColor) throws -> Data {
    let encoded = try png(color)
    var result = Data(encoded.prefix(8))
    var offset = 8
    while offset + 12 <= encoded.count {
        let size = encoded[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
        let end = offset + 12 + size
        let type = String(decoding: encoded[(offset + 4)..<(offset + 8)], as: UTF8.self)
        guard end <= encoded.count else { throw CocoaError(.fileReadCorruptFile) }
        if ["IHDR", "IDAT", "IEND"].contains(type) { result.append(encoded[offset..<end]) }
        offset = end
    }
    try WebsiteIconService.validatePNG(result)
    return result
}

private actor LocalReader {
    private var bytes: Data
    var calls = 0
    init(_ bytes: Data) { self.bytes = bytes }
    func read() -> Data {
        calls += 1
        return bytes
    }
    func replace(_ bytes: Data) { self.bytes = bytes }
}

private actor LocalGate {
    private var reader: CheckedContinuation<Data?, Never>?
    func read() async -> Data? { await withCheckedContinuation { reader = $0 } }
    func waitUntilStarted() async { while reader == nil { await Task.yield() } }
    func finish(_ bytes: Data) {
        reader?.resume(returning: bytes)
        reader = nil
    }
}

private func icon(_ url: String, bytes: Data, revision: Int64 = 1) throws -> WebsiteIconRecord {
    WebsiteIconRecord(
        origin: try #require(WebsiteIconOrigin(url: url)), revision: revision,
        content: WebsiteIconContent(blob: BlobReference(data: bytes)))
}

@MainActor
private func png(_ color: NSColor) throws -> Data {
    let bitmap = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    color.setFill()
    NSRect(x: 0, y: 0, width: 64, height: 64).fill()
    NSGraphicsContext.restoreGraphicsState()
    return try #require(bitmap.representation(using: .png, properties: [:]))
}
