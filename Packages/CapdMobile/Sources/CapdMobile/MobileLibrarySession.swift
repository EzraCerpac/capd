import CapdSync
import Darwin
import Foundation

public struct MobileLibrarySessionToken: Equatable, Sendable {
    public let generation: UUID
    public let binding: SyncLibraryBinding?
}

public struct MobileSavedProjection: Sendable {
    public let capture: MobileCapture
    public let sessionToken: MobileLibrarySessionToken
    public var libraryID: UUID? { sessionToken.binding?.libraryID }
}

/// App and share use the identical selector. Share has no network/Keychain adapter.
public final class MobileLibrarySession: Sendable {
    public enum Role: Sendable { case app, shareExtension }
    public let store: MobileStore
    public let adapter: any MobileSyncAdapter
    public let configuration: MobileLibraryConfiguration
    private let access: MobileLibraryAccess

    public var token: MobileLibrarySessionToken {
        .init(generation: configuration.generation, binding: configuration.enrollment?.binding)
    }

    public static func open(
        root: URL, role: Role,
        credentials: any SyncCredentialStore = KeychainSyncCredentialStore(
            service: "dev.jxd.capd.phone.sync")
    )
        throws -> MobileLibrarySession
    {
        let lease = try MobileLibraryLease(root: root, exclusive: false)
        defer { withExtendedLifetime(lease) {} }
        let configuration = try MobileLibraryAccess.selected(in: root)
        let access = MobileLibraryAccess(root: root, configuration: configuration)
        let store = try MobileStore(
            url: configuration.databaseURL(in: root),
            deviceID: configuration.enrollment?.deviceID,
            binding: configuration.enrollment?.binding, access: access)
        let adapter: any MobileSyncAdapter
        if case .app = role, let enrollment = configuration.enrollment {
            adapter = try EnrolledSyncAdapter(
                enrollment: enrollment, store: store, credentials: credentials)
        } else {
            adapter = LocalOnlySyncAdapter()
        }
        return .init(store: store, adapter: adapter, configuration: configuration, access: access)
    }

    private init(
        store: MobileStore, adapter: any MobileSyncAdapter,
        configuration: MobileLibraryConfiguration, access: MobileLibraryAccess
    ) {
        self.store = store
        self.adapter = adapter
        self.configuration = configuration
        self.access = access
    }

    public func isCurrent(_ token: MobileLibrarySessionToken) -> Bool {
        guard token == self.token, let lease = try? access.lease() else { return false }
        withExtendedLifetime(lease) {}
        return true
    }

    public func save(_ capture: MobileCapture) throws -> MobileSavedProjection {
        let canonical = try store.saveProjected(capture)
        return .init(capture: canonical, sessionToken: token)
    }

    /// Reads through this session's store and fence; does not guess paths or reopen a DB.
    public func capture(id: UUID) throws -> MobileSavedProjection? {
        try store.canonicalCapture(id: id).map { .init(capture: $0, sessionToken: token) }
    }

    public func websiteIcon(for url: String, token: MobileLibrarySessionToken) throws
        -> WebsiteIconRecord?
    {
        guard token == self.token else { throw MobileActivationError.sessionReplaced }
        let lease = try access.lease()
        defer { withExtendedLifetime(lease) {} }
        return try store.websiteIcon(for: url)
    }

    public func websiteIconData(
        _ record: WebsiteIconRecord, token: MobileLibrarySessionToken
    ) throws -> Data? {
        guard token == self.token else { throw MobileActivationError.sessionReplaced }
        let lease = try access.lease()
        defer { withExtendedLifetime(lease) {} }
        return try store.websiteIconData(record)
    }

    public func websiteIconRecord(for url: String, token: MobileLibrarySessionToken) throws
        -> WebsiteIconRecord?
    {
        guard token == self.token else { throw MobileActivationError.sessionReplaced }
        let lease = try access.lease()
        defer { withExtendedLifetime(lease) {} }
        return try store.websiteIconRecord(for: url)
    }

    /// Retained global cache is usable only with a verified, durable owner for this selected library.
    public func legacyWebsiteIconDirectory(for url: String, token: MobileLibrarySessionToken) throws
        -> URL?
    {
        guard token == self.token else { throw MobileActivationError.sessionReplaced }
        let lease = try access.lease()
        defer { withExtendedLifetime(lease) {} }
        guard let origin = WebsiteIconOrigin(url: url),
            try store.websiteIconRecord(for: url) == nil,
            try store.hasWebsiteIconOrigin(origin)
        else { return nil }
        let marker = access.root.appendingPathComponent("Library/legacy-website-icons-library.json")
        guard marker == marker.resolvingSymlinksInPath(),
            let values = try? marker.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, (1...8192).contains(size),
            let bytes = try? Self.readLegacyOwner(marker, size: size), bytes.count == size,
            let owner = try? JSONDecoder().decode(MobileLibraryConfiguration.self, from: bytes),
            owner == configuration
        else { return nil }
        let directory = access.root.appendingPathComponent(
            "Library/Caches/WebsiteIcons", isDirectory: true)
        guard directory == directory.resolvingSymlinksInPath() else { return nil }
        return directory
    }

    private static func readLegacyOwner(_ file: URL, size: Int) throws -> Data {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw MobileActivationError.invalidConfiguration }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_size == size
        else { throw MobileActivationError.invalidConfiguration }
        return try handle.read(upToCount: 8193) ?? Data()
    }

    /// App index updates and extension donation/repair use the same cross-process lock.
    /// Hold this through journal ownership checks and the exact-ID OS operation;
    /// an isCurrent check followed by an unlocked deletion is insufficient.
    public func withSystemSearchLease<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let current = try access.lease()
        let search = try MobileLibraryLease(
            root: access.root, exclusive: true,
            fileName: ".system-search.lock")
        defer { withExtendedLifetime((current, search)) {} }
        return try await operation()
    }
}
