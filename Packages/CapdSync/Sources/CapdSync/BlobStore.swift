import Crypto
import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public struct BlobReference: Codable, Equatable, Sendable {
    public let digest: String
    public let byteCount: Int

    public init(digest: String, byteCount: Int) {
        self.digest = digest
        self.byteCount = byteCount
    }

    public init(data: Data) {
        self.init(digest: Self.digest(data), byteCount: data.count)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard digest.count == 64,
            digest.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }), (0...8_388_608).contains(byteCount)
        else { throw SyncError.invalidBlob }
    }
}

/// Bounded synthetic blobs; callers retain published files for the lifetime of this store.
public final class BlobStore: Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL, binding: SyncLibraryBinding? = nil) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.checkOwnership(directory, binding: binding)
    }

    private static func checkOwnership(_ directory: URL, binding: SyncLibraryBinding?) throws {
        let marker = directory.appendingPathComponent("library-owner")
        func verify() throws {
            guard let binding,
                try SyncDatabase.decode(SyncLibraryBinding.self, Data(contentsOf: marker))
                    == binding
            else {
                throw SyncBindingError.mismatch
            }
        }
        if FileManager.default.fileExists(atPath: marker.path) { return try verify() }
        guard let binding else { return }
        guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw SyncBindingError.enrollmentRequiresEmptyLibrary
        }
        // Exclusive creation fails closed on competing enrollment or an interrupted ownership write.
        let fd = open(marker.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        if fd < 0 {
            guard errno == EEXIST else { throw SyncBindingError.mismatch }
            return try verify()
        }
        defer { _ = close(fd) }
        let bytes = try SyncDatabase.encode(binding)
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count, fsync(fd) == 0 else { throw SyncBindingError.mismatch }
    }

    public func read(_ blob: BlobReference) throws -> Data {
        try lock.withLock { try verifiedRead(blob) }
    }

    private func verifiedRead(_ blob: BlobReference) throws -> Data {
        try blob.validate()
        let url = directory.appendingPathComponent(blob.digest)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SyncError.blobMissing }
        let data = try Data(contentsOf: url)
        guard data.count == blob.byteCount, BlobReference.digest(data) == blob.digest else {
            throw SyncError.invalidBlob
        }
        return data
    }

    public func receive(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try lock.withLock {
            try blob.validate()
            let published = directory.appendingPathComponent(blob.digest)
            if FileManager.default.fileExists(atPath: published.path) {
                do {
                    _ = try verifiedRead(blob)
                    return
                } catch SyncError.invalidBlob {
                    // Keep the old path until a verified replacement is atomically published.
                }
            }
            let partial = directory.appendingPathComponent(blob.digest + ".partial")
            var data =
                FileManager.default.fileExists(atPath: partial.path)
                ? try Data(contentsOf: partial) : Data()
            guard offset >= 0, offset <= data.count, chunk.count <= blob.byteCount,
                offset <= blob.byteCount - chunk.count
            else { throw SyncError.invalidOffset }
            if offset < data.count {
                guard offset + chunk.count <= data.count,
                    data.subdata(in: offset..<(offset + chunk.count)) == chunk
                else {
                    throw SyncError.invalidOffset
                }
            } else {
                data.append(chunk)
                try data.write(to: partial, options: .atomic)
            }
            if final {
                guard data.count == blob.byteCount,
                    BlobReference.digest(data) == blob.digest
                else {
                    // A poisoned partial cannot be repaired by retrying its final chunk.
                    try FileManager.default.removeItem(at: partial)
                    throw SyncError.invalidBlob
                }
                try data.write(to: published, options: .atomic)
                try? FileManager.default.removeItem(at: partial)
            }
        }
    }

    public func put(_ data: Data) throws -> BlobReference {
        let blob = BlobReference(data: data)
        try receive(blob, offset: 0, chunk: data, final: true)
        return blob
    }
}
