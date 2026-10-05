import CapdSync
import Foundation

public enum MacSyncError: Error, Equatable, Sendable {
    case invalidConfiguration, configurationRequired, configurationChanged, busy,
        noteConflictChanged
}

extension MacSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The Mac sync configuration is invalid."
        case .configurationRequired:
            "This library is bound. Restore its matching sync configuration before opening it."
        case .configurationChanged: "The sync configuration changed. Reopen the library."
        case .busy: "Another Capd process is synchronizing this library."
        case .noteConflictChanged: "This note conflict changed. Review its current versions."
        }
    }
}

public struct MacSyncConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let endpoint: URL
    public let binding: SyncLibraryBinding
    public let deviceID: UUID
    public let loopbackSOCKSPort: Int?
    public var enabled: Bool

    public init(
        enrollment: SyncEnrollment, enabled: Bool = true, loopbackSOCKSPort: Int? = nil
    ) {
        version = 1
        endpoint = enrollment.endpoint
        binding = enrollment.binding
        deviceID = enrollment.deviceID
        self.enabled = enabled
        self.loopbackSOCKSPort = loopbackSOCKSPort
    }

    public func enrollment() throws -> SyncEnrollment {
        guard version == 1, loopbackSOCKSPort.map({ (1...65_535).contains($0) }) ?? true else {
            throw MacSyncError.invalidConfiguration
        }
        return try SyncEnrollment(endpoint: endpoint, binding: binding, deviceID: deviceID)
    }

    public static func url(paths: StoragePaths) -> URL {
        paths.root.appendingPathComponent("sync-configuration.json")
    }

    public static func load(paths: StoragePaths) throws -> Self? {
        guard let bytes = try bytes(paths: paths) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        _ = try value.enrollment()
        return value
    }

    static func bytes(paths: StoragePaths) throws -> Data? {
        let file = url(paths: paths)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            (values.fileSize ?? Int.max) <= 16_384
        else { throw MacSyncError.invalidConfiguration }
        return try Data(contentsOf: file)
    }

    func install(paths: StoragePaths) throws {
        _ = try enrollment()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try Self.restore(encoder.encode(self), paths: paths)
    }

    static func restore(_ bytes: Data?, paths: StoragePaths) throws {
        let file = url(paths: paths)
        if let bytes {
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
