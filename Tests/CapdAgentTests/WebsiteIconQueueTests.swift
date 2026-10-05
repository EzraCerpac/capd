import CapdKit
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import CapdAgent

@Suite("Agent website icon queue")
struct WebsiteIconQueueTests {
    @Test func boundedDrainAndOverlap() async throws {
        let paths = StoragePaths(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(
                "capd-icon-worker-test-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = try Store(paths: paths)
        for index in 0..<4 {
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://icon\(index).example.org/path", fetchBody: false))
        }
        try store.setWebsiteIconsEnabled(true)
        let bytes = try workerPNG()
        let first = WorkerFetchLatch()
        let count = Mutex(0)
        let queue = WebsiteIconQueue(
            service: WebsiteIconService(
                store: store,
                fetch: { _ in
                    let attempt = count.withLock { value in
                        value += 1
                        return value
                    }
                    if attempt == 1 { await first.suspend() }
                    return .normalizedPNG(bytes)
                }))
        let task = Task { await queue.drain(limit: 100) }
        await first.waitUntilStarted()
        await queue.drain()
        #expect(count.withLock { $0 } == 1)
        await first.release()
        await task.value
        #expect(count.withLock { $0 } == 3)
        #expect(try store.storedWebsiteIcons().count == 3)
        await queue.drain()
        #expect(count.withLock { $0 } == 4)
        #expect(try store.storedWebsiteIcons().count == 4)
    }
}

private actor WorkerFetchLatch {
    var started = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() {
        waiter?.resume()
        waiter = nil
    }
}

private func workerPNG() throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let encoded = data as Data
    var stripped = Data(encoded.prefix(8))
    var offset = 8
    while offset + 12 <= encoded.count {
        let size = encoded[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
        let end = offset + 12 + size
        let type = String(decoding: encoded[(offset + 4)..<(offset + 8)], as: UTF8.self)
        guard end <= encoded.count else { throw CocoaError(.fileReadCorruptFile) }
        if ["IHDR", "IDAT", "IEND"].contains(type) { stripped.append(encoded[offset..<end]) }
        offset = end
    }
    return stripped
}
