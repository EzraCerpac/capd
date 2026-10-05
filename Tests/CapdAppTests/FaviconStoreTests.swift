import AppKit
import CapdSync
import Foundation
import Testing

@testable import CapdAppUI
@testable import CapdKit

@MainActor
@Suite("Offline favicon store")
struct FaviconStoreTests {
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
