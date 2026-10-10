import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CapdWebsiteIcons

struct LegacyWebsiteIconPNGTests {
    @Test(arguments: [16, 32, 48, 64])
    func readsOldPixelsWithoutChangingTheOriginal(size: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("synthetic.png")
        let original = try legacyPNG(size)
        try original.write(to: file)
        let bytes = try #require(try LegacyWebsiteIconPNG.read(at: file))
        let identity = WebsiteIconIdentity(
            library: "synthetic", generation: UUID(), originID: "synthetic",
            revision: 0, normalizerVersion: 1,
            digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(WebsiteIconImage.decode(bytes, identity: identity)?.image.width == 64)
        #expect(try Data(contentsOf: file) == original)
        #expect(try LegacyWebsiteIconPNG.read(at: file) == bytes)
    }

    @Test(arguments: [
        "corrupt", "crc", "truncated", "oversize", "dimensions", "symlink", "directory",
    ])
    func refusesUnusableOrRedirectedFiles(problem: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("synthetic.png")
        var bytes = try legacyPNG(problem == "dimensions" ? 65 : 64)
        if problem == "corrupt" { bytes = Data("not PNG".utf8) }
        if problem == "crc" { bytes[29] ^= 1 }
        if problem == "truncated" { bytes.removeLast() }
        if problem == "oversize" { bytes = Data(count: WebsiteIconImage.byteLimit + 1) }
        if problem == "symlink" {
            let target = root.appendingPathComponent("original.png")
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        } else if problem == "directory" {
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        } else {
            try bytes.write(to: file)
        }
        #expect(try LegacyWebsiteIconPNG.read(at: file) == nil)
    }
}

private func legacyPNG(_ size: Int) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}
