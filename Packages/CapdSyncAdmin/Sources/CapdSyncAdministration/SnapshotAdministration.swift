import CapdSync
import Foundation
import GRDB

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public enum AdministrationError: Error, Equatable, Sendable {
    case invalidArguments, unsafePath, invalidAuthority, authorityBusy
    case invalidAsset, invalidReview, changedInputs, staleReview
}

public struct SnapshotReview: Codable, Equatable, Sendable {
    public let version: Int
    public let authorityDirectory: String
    public let snapshotSHA256: String
    public let assets: [BlobReference]
    public let preview: ContentSnapshotImportPreview
}

/// Local, exclusive administration of an already bound authority; no listener or enrollment.
public final class SnapshotAdministration {
    private let root: URL
    private let binding: SyncLibraryBinding
    private let lockDescriptor: Int32
    private let server: SyncServer

    public init(dataDirectory: URL, binding: SyncLibraryBinding) throws {
        try SafeFiles.directory(dataDirectory)
        root = dataDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.binding = binding
        let lockURL = root.appendingPathComponent(".server.lock")
        let descriptor = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AdministrationError.invalidAuthority }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_size == 0, status.st_nlink == 1
        else {
            close(descriptor)
            throw AdministrationError.invalidAuthority
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw AdministrationError.authorityBusy
        }
        do {
            let service = try JSONDecoder().decode(
                UUID.self,
                from: SafeFiles.read(root.appendingPathComponent("service.json"), maximum: 1_024))
            guard service == binding.serviceID else { throw AdministrationError.invalidAuthority }
            let library = root.appendingPathComponent(binding.libraryID.uuidString.lowercased())
            try SafeFiles.directory(library)
            let database = library.appendingPathComponent("authority.sqlite")
            try SafeFiles.regular(database)
            for suffix in ["-wal", "-shm", "-journal"] {
                let sidecar = URL(fileURLWithPath: database.path + suffix)
                if SafeFiles.exists(sidecar) { try SafeFiles.regular(sidecar) }
            }
            let blobs = library.appendingPathComponent("blobs")
            try SafeFiles.directory(blobs)
            let owner = try JSONDecoder().decode(
                SyncLibraryBinding.self,
                from: SafeFiles.read(blobs.appendingPathComponent("library-owner"), maximum: 1_024))
            guard owner == binding else { throw AdministrationError.invalidAuthority }
            var config = Configuration()
            config.readonly = true
            let reader = try DatabaseQueue(path: database.path, configuration: config)
            try reader.read { db in
                for table in [
                    "sync_meta", "sync_records", "sync_aliases", "sync_receipts", "sync_devices",
                    "sync_feed", "sync_outbox", "sync_visible", "sync_rejections", "sync_observed",
                    "sync_binding",
                ] {
                    guard try db.tableExists(table) else {
                        throw AdministrationError.invalidAuthority
                    }
                }
                let stored = try Data.fetchOne(
                    db, sql: "SELECT payload FROM sync_binding WHERE id = 1")
                guard let stored,
                    try JSONDecoder().decode(SyncLibraryBinding.self, from: stored) == binding,
                    let row = try Row.fetchOne(
                        db, sql: "SELECT role, device FROM sync_meta WHERE id = 1"),
                    (row["role"] as String) == "server", (row["device"] as String?) == nil
                else { throw AdministrationError.invalidAuthority }
            }
            server = try SyncServer(
                databaseURL: database, blobDirectory: blobs,
                libraryID: binding.libraryID, serviceID: binding.serviceID)
            lockDescriptor = descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit { close(lockDescriptor) }

    public func preview(snapshotURL: URL, assetDirectory: URL) throws -> SnapshotReview {
        let input = try load(snapshotURL: snapshotURL, assetDirectory: assetDirectory)
        return SnapshotReview(
            version: 1, authorityDirectory: root.path,
            snapshotSHA256: BlobReference(data: input.bytes).digest, assets: input.assets,
            preview: try server.previewContentSnapshotImport(input.snapshot))
    }

    /// Requires the exact independently reviewed artifact hash and revalidates before publishing assets.
    public func importSnapshot(
        snapshotURL: URL, assetDirectory: URL, reviewURL: URL, reviewedSHA256: String
    ) throws -> ContentSnapshotImportReceipt {
        guard SafeFiles.isDigest(reviewedSHA256) else { throw AdministrationError.invalidReview }
        let bytes = try SafeFiles.read(reviewURL, maximum: Self.maximumReviewBytes)
        guard BlobReference(data: bytes).digest == reviewedSHA256 else {
            throw AdministrationError.invalidReview
        }
        let review = try JSONDecoder().decode(SnapshotReview.self, from: bytes)
        guard review.version == 1, review.authorityDirectory == root.path,
            review.preview.targetBinding == binding
        else { throw AdministrationError.invalidReview }
        let input = try load(snapshotURL: snapshotURL, assetDirectory: assetDirectory)
        guard BlobReference(data: input.bytes).digest == review.snapshotSHA256,
            input.assets == review.assets
        else { throw AdministrationError.changedInputs }
        guard try server.previewContentSnapshotImport(input.snapshot) == review.preview else {
            throw AdministrationError.staleReview
        }
        var published: [URL] = []
        do {
            for blob in input.assets {
                let destination = server.blobs.directory.appendingPathComponent(blob.digest)
                if SafeFiles.exists(destination) {
                    _ = try verifiedAsset(destination, blob: blob)
                } else {
                    let source = assetDirectory.appendingPathComponent(blob.digest)
                    let data = try verifiedAsset(source, blob: blob)
                    try SafeFiles.writeNew(data, to: destination)
                    published.append(destination)
                }
            }
            return try server.importContentSnapshot(input.snapshot, preview: review.preview)
        } catch {
            for url in published { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    public static func writeReview(_ review: SnapshotReview, to url: URL) throws -> String {
        let bytes = try encode(review)
        guard bytes.count <= maximumReviewBytes else { throw AdministrationError.invalidReview }
        try SafeFiles.writeNew(bytes, to: url)
        return BlobReference(data: bytes).digest
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value)
    }

    private static let maximumReviewBytes = SyncHTTPHandler.maximumBodyBytes * 4
    public static let maximumAssetCount = 4_096
    public static let maximumAssetBytes = 1_073_741_824

    private func load(snapshotURL: URL, assetDirectory: URL) throws
        -> (bytes: Data, snapshot: ContentSnapshotImport, assets: [BlobReference])
    {
        try SafeFiles.directory(assetDirectory)
        let bytes = try SafeFiles.read(snapshotURL, maximum: SyncHTTPHandler.maximumBodyBytes)
        let snapshot = try JSONDecoder().decode(ContentSnapshotImport.self, from: bytes)
        guard snapshot.targetBinding == binding else { throw AdministrationError.invalidAuthority }
        var assets: [String: BlobReference] = [:]
        for capture in snapshot.captures {
            guard let blob = capture.source.blob else { continue }
            guard SafeFiles.isDigest(blob.digest), (0...8_388_608).contains(blob.byteCount),
                assets[blob.digest] == nil || assets[blob.digest] == blob
            else { throw AdministrationError.invalidAsset }
            assets[blob.digest] = blob
        }
        let ordered = assets.values.sorted { $0.digest < $1.digest }
        guard ordered.count <= Self.maximumAssetCount,
            ordered.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= Self.maximumAssetBytes
        else { throw AdministrationError.invalidAsset }
        for blob in ordered {
            _ = try verifiedAsset(assetDirectory.appendingPathComponent(blob.digest), blob: blob)
            let destination = server.blobs.directory.appendingPathComponent(blob.digest)
            if SafeFiles.exists(destination) { _ = try verifiedAsset(destination, blob: blob) }
        }
        return (bytes, snapshot, ordered)
    }

    private func verifiedAsset(_ url: URL, blob: BlobReference) throws -> Data {
        let bytes = try SafeFiles.read(url, maximum: blob.byteCount)
        guard BlobReference(data: bytes) == blob else { throw AdministrationError.invalidAsset }
        return bytes
    }
}

enum SafeFiles {
    static func exists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    static func directory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw AdministrationError.unsafePath
        }
    }

    static func regular(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_nlink == 1
        else { throw AdministrationError.unsafePath }
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func read(_ url: URL, maximum: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AdministrationError.unsafePath }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_nlink == 1, status.st_size <= maximum
        else { throw AdministrationError.unsafePath }
        let bytes = try file.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw AdministrationError.unsafePath }
        return bytes
    }

    static func writeNew(_ bytes: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".capd-admin-\(UUID()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AdministrationError.unsafePath }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var published = false
        do {
            try file.write(contentsOf: bytes)
            try file.synchronize()
            try file.close()
            guard link(temporary.path, url.path) == 0 else { throw AdministrationError.unsafePath }
            published = true
            try FileManager.default.removeItem(at: temporary)
            let directory = open(
                url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directory >= 0 else { throw AdministrationError.unsafePath }
            defer { close(directory) }
            guard fsync(directory) == 0 else { throw AdministrationError.unsafePath }
        } catch {
            try? file.close()
            if published { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}
