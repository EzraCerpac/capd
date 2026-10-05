import Foundation

public enum CaptureFingerprint {
    public static func contentHash(for url: URL) -> String {
        contentHash(for: Data(URLNormalizer.normalize(url).utf8))
    }

    public static func contentHash(for data: Data) -> String { BlobReference(data: data).digest }

    static func matches(_ lhs: CaptureSource, _ rhs: CaptureSource) -> Bool {
        guard let hash = lhs.contentHash, hash == rhs.contentHash, lhs.kind == rhs.kind else {
            return false
        }
        return lhs.kind != .image || lhs.blob == rhs.blob
    }
}
