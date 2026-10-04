import CapdSync
import Darwin
import Foundation

/// Synchronous SQLite/file work runs on one dedicated queue, never on a NIO event loop.
public final class Authority: @unchecked Sendable {
    private let queue = DispatchQueue(label: "capd.sync.authority")
    private let dataDirectory: URL
    private let serviceID: UUID
    private let authorizer: ConfigurationAuthorizer
    private let lockDescriptor: Int32
    private var servers: [UUID: SyncServer] = [:]

    public init(configurationURL: URL, dataDirectory: URL) throws {
        let configuration = try HostConfiguration.read(configurationURL)
        serviceID = configuration.serviceID
        authorizer = ConfigurationAuthorizer(
            configurationURL: configurationURL, serviceID: serviceID)
        self.dataDirectory = dataDirectory
        lockDescriptor = try Self.lockDirectory(dataDirectory)
        do { try Self.bindDirectory(dataDirectory, serviceID: serviceID) } catch {
            close(lockDescriptor)
            throw error
        }
    }

    deinit { close(lockDescriptor) }

    public func handle(_ request: SyncHTTPRequest) async -> SyncHTTPResponse {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let handler = SyncHTTPHandler(serviceID: serviceID, authorizer: authorizer) {
                    [self] id in
                    if let existing = servers[id] { return existing }
                    let root = dataDirectory.appendingPathComponent(
                        id.uuidString.lowercased(), isDirectory: true)
                    try Self.validateStoragePath(root, directory: true)
                    try Self.validateStoragePath(
                        root.appendingPathComponent("blobs"), directory: true)
                    for name in [
                        "authority.sqlite", "authority.sqlite-wal", "authority.sqlite-shm",
                        "authority.sqlite-journal",
                    ] {
                        try Self.validateStoragePath(root.appendingPathComponent(name))
                    }
                    let server = try SyncServer(
                        databaseURL: root.appendingPathComponent("authority.sqlite"),
                        blobDirectory: root.appendingPathComponent("blobs", isDirectory: true),
                        libraryID: id, serviceID: serviceID)
                    servers[id] = server
                    return server
                }
                continuation.resume(returning: handler.handle(request))
            }
        }
    }

    private static func validateStoragePath(_ path: URL, directory: Bool = false) throws {
        var status = stat()
        if lstat(path.path, &status) != 0 {
            guard errno == ENOENT else { throw HostError.invalidDataDirectory }
            return
        }
        guard status.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
            directory || status.st_nlink == 1
        else {
            throw HostError.invalidDataDirectory
        }
    }

    private static func lockDirectory(_ directory: URL) throws -> Int32 {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw HostError.invalidDataDirectory
        }
        if !fm.fileExists(atPath: directory.appendingPathComponent("service.json").path) {
            let contents = try fm.contentsOfDirectory(atPath: directory.path)
            let lock = directory.appendingPathComponent(".server.lock")
            let onlyAbandonedLock: Bool
            if contents == [".server.lock"] {
                let lockValues: URLResourceValues? = try? lock.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                ])
                let isRegularFile: Bool = lockValues?.isRegularFile == true
                let isSymbolicLink: Bool = lockValues?.isSymbolicLink == true
                let isEmptyFile: Bool = lockValues?.fileSize == 0
                onlyAbandonedLock = isRegularFile && !isSymbolicLink && isEmptyFile
            } else {
                onlyAbandonedLock = false
            }
            guard contents.isEmpty || onlyAbandonedLock else {
                throw HostError.invalidDataDirectory
            }
        }
        let fd = open(
            directory.appendingPathComponent(".server.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW,
            0o600)
        guard fd >= 0 else { throw HostError.invalidDataDirectory }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw HostError.invalidDataDirectory
        }
        return fd
    }

    private static func bindDirectory(_ directory: URL, serviceID: UUID) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw HostError.invalidDataDirectory
        }
        let binding = directory.appendingPathComponent("service.json")
        if fm.fileExists(atPath: binding.path) {
            let fd = open(binding.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw HostError.invalidDataDirectory }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            var status = stat()
            guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                (1...1_024).contains(status.st_size)
            else { throw HostError.invalidDataDirectory }
            let bytes = try file.read(upToCount: 1_025) ?? Data()
            guard bytes.count <= 1_024 else { throw HostError.invalidDataDirectory }
            guard try JSONDecoder().decode(UUID.self, from: bytes) == serviceID
            else {
                throw HostError.serviceChanged
            }
        } else {
            try JSONEncoder().encode(serviceID).write(
                to: binding, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binding.path)
        }
    }
}

/// Admission is acquired before body collection, bounding queued bodies and worker submissions.
actor Admission {
    private var active = 0
    func acquire() -> Bool {
        guard active < 8 else { return false }
        active += 1
        return true
    }
    func release() { active -= 1 }
}
