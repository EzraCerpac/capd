import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum WebsiteIconImage {
    static func normalizedPNG(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= WebsiteIconHTTPParser.bodyLimit,
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetStatus(source) == .statusComplete,
            let type = CGImageSourceGetType(source) as String?,
            [UTType.png.identifier, UTType.jpeg.identifier, UTType.ico.identifier].contains(type)
        else { return nil }
        if type == UTType.png.identifier, !completePNG(data) { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= (type == UTType.ico.identifier ? 32 : 1) else { return nil }
        var best = 0
        var bestEdge = 0
        var pixels = 0
        for index in 0..<count {
            guard
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                (1...4096).contains(width), (1...4096).contains(height),
                CGImageSourceGetStatusAtIndex(source, index) == .statusComplete
            else { return nil }
            pixels += width * height
            guard pixels <= 4096 * 4096 else { return nil }
            if max(width, height) > bestEdge {
                best = index
                bestEdge = max(width, height)
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, best, options as CFDictionary),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 256, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = min(64 / Double(thumbnail.width), 64 / Double(thumbnail.height))
        let width = Double(thumbnail.width) * scale
        let height = Double(thumbnail.height) * scale
        context.clear(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.draw(
            thumbnail,
            in: CGRect(x: (64 - width) / 2, y: (64 - height) / 2, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
            output.length <= WebsiteIconHTTPParser.bodyLimit
        else { return nil }
        return pixelChunks(output as Data)
    }

    private static func completePNG(_ data: Data) -> Bool {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return false }
        var position = 8
        var ended = false
        while position <= data.count - 12 {
            let length = data[position..<position + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= data.count - position - 12 else { return false }
            let name = String(decoding: data[position + 4..<position + 8], as: UTF8.self)
            guard !["acTL", "fcTL", "fdAT"].contains(name) else { return false }
            let expected = data[position + 8 + length..<position + 12 + length].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            var crc: UInt32 = .max
            for byte in data[position + 4..<position + 8 + length] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
            }
            guard ~crc == expected else { return false }
            position += length + 12
            if name == "IEND" {
                guard length == 0 else { return false }
                ended = true
                break
            }
        }
        return ended && position == data.count
    }

    private static func pixelChunks(_ encoded: Data) -> Data? {
        let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
        guard encoded.starts(with: signature) else { return nil }
        var result = signature
        var position = 8
        var ended = false
        while position <= encoded.count - 12 {
            let length = encoded[position..<position + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= encoded.count - position - 12 else { return nil }
            let type = String(decoding: encoded[position + 4..<position + 8], as: UTF8.self)
            if ["IHDR", "IDAT", "IEND"].contains(type) {
                result.append(encoded[position..<position + length + 12])
            }
            position += length + 12
            if type == "IEND" {
                ended = true
                break
            }
        }
        return ended && position == encoded.count ? result : nil
    }
}
