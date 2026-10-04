import Foundation

public enum CaptureFingerprint {
    public static func contentHash(for url: URL) -> String {
        contentHash(for: Data(URLNormalizer.normalize(url).utf8))
    }

    public static func contentHash(for data: Data) -> String { BlobReference(data: data).digest }
}
