import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct WebsiteIconImage: Sendable {
    public let image: CGImage
    public static let byteLimit = 256 * 1024

    public static func decode(_ data: Data, identity: WebsiteIconIdentity) -> Self? {
        guard identity.normalizerVersion == 1, !data.isEmpty, data.count <= byteLimit,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
                == identity.digest,
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
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return .init(image: image)
    }
}
