import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads retained cache pixels without fetching, rewriting, or promoting them to synced assets.
public enum LegacyWebsiteIconPNG {
    public static func read(at file: URL) throws -> Data? {
        guard file.standardizedFileURL == file.resolvingSymlinksInPath() else { return nil }
        let values = try file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, (1...WebsiteIconImage.byteLimit).contains(size)
        else { return nil }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_size == size
        else { return nil }
        let data = try handle.read(upToCount: WebsiteIconImage.byteLimit + 1) ?? Data()
        guard data.count == size else { return nil }
        return normalized(data)
    }

    static func normalized(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= WebsiteIconImage.byteLimit, completePNG(data),
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetType(source) as String? == UTType.png.identifier,
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...64).contains(width), (1...64).contains(height),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = min(64 / Double(width), 64 / Double(height))
        let w = Double(width) * scale
        let h = Double(height) * scale
        context.draw(image, in: CGRect(x: (64 - w) / 2, y: (64 - h) / 2, width: w, height: h))
        guard let pixels = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination), output.length <= WebsiteIconImage.byteLimit
        else { return nil }
        return output as Data
    }

    private static func completePNG(_ data: Data) -> Bool {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { return false }
        var offset = 8
        while data.count - offset >= 12 {
            let length = data[offset..<offset + 4].reduce(0) { $0 * 256 + Int($1) }
            guard length <= data.count - offset - 12 else { return false }
            let end = offset + 8 + length
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            guard !["acTL", "fcTL", "fdAT"].contains(type) else { return false }
            var crc = UInt32.max
            for byte in data[offset + 4..<end] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
            }
            let expected = data[end..<end + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard ~crc == expected else { return false }
            offset = end + 4
            if type == "IEND" { return length == 0 && offset == data.count }
        }
        return false
    }
}
