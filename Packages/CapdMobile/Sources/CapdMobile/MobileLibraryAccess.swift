import Darwin
import Foundation

/// Short leases cover every managed store operation, including in-flight sync.
/// Exclusive activation holds the same lock through publication and rollback.
public struct MobileLibraryAccess: Sendable {
    public let root: URL
    public let configuration: MobileLibraryConfiguration

    public init(root: URL, configuration: MobileLibraryConfiguration) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.configuration = configuration
    }

    func lease() throws -> MobileLibraryLease {
        let lease = try MobileLibraryLease(root: root, exclusive: false)
        guard try Self.selected(in: root) == configuration else {
            throw MobileActivationError.sessionReplaced
        }
        return lease
    }

    public static func selected(in root: URL) throws -> MobileLibraryConfiguration {
        let path = root.appendingPathComponent("active-library.json")
        var status = stat()
        if lstat(path.path, &status) != 0 {
            guard errno == ENOENT else { throw MobileActivationError.invalidConfiguration }
            return .legacy
        }
        let values = try path.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            (values.fileSize ?? Int.max) <= 8_192
        else { throw MobileActivationError.invalidConfiguration }
        let configuration = try JSONDecoder().decode(
            MobileLibraryConfiguration.self,
            from: Data(contentsOf: path))
        try configuration.validate()
        _ = try configuration.databaseURL(in: root)
        return configuration
    }

    static func publish(_ configuration: MobileLibraryConfiguration, in root: URL) throws {
        try configuration.validate()
        _ = try configuration.databaseURL(in: root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(configuration).write(
            to: root.appendingPathComponent("active-library.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

final class MobileLibraryLease: @unchecked Sendable {
    private let descriptor: Int32

    init(root: URL, exclusive: Bool, fileName: String = ".library-transition.lock") throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(fileName).path
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_nlink == 1, status.st_size == 0
        else {
            close(descriptor)
            throw MobileActivationError.invalidConfiguration
        }
        if flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            let failure = errno
            close(descriptor)
            if failure == EWOULDBLOCK || failure == EAGAIN {
                throw MobileActivationError.transitionBusy
            }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
