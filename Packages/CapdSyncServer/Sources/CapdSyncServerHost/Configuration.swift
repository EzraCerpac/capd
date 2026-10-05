import CapdSync
import CryptoKit
import Foundation

public enum HostError: Error, Sendable {
    case invalidArguments
    case invalidConfiguration
    case serviceChanged
    case invalidDataDirectory
}

public struct HostConfiguration: Codable, Sendable {
    public struct Enrollment: Codable, Sendable {
        public let libraryID: UUID
        public let deviceID: UUID
        public let credentialSHA256: String
        public let revoked: Bool
    }

    public let serviceID: UUID
    public let enrollments: [Enrollment]

    public static func read(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...1_048_576).contains(size) else { throw HostError.invalidConfiguration }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == ["serviceID", "enrollments"],
            let rows = object["enrollments"] as? [[String: Any]],
            rows.allSatisfy({
                Set($0.keys) == ["libraryID", "deviceID", "credentialSHA256", "revoked"]
            })
        else { throw HostError.invalidConfiguration }
        let config = try JSONDecoder().decode(Self.self, from: data)
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard config.serviceID != zero, (1...1_024).contains(config.enrollments.count) else {
            throw HostError.invalidConfiguration
        }
        var digests = Set<String>()
        var devices = Set<UUID>()
        for row in config.enrollments {
            guard row.libraryID != zero, row.deviceID != zero,
                Self.isDigest(row.credentialSHA256), digests.insert(row.credentialSHA256).inserted,
                devices.insert(row.deviceID).inserted
            else { throw HostError.invalidConfiguration }
        }
        return config
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public func principal(for credential: String) -> SyncPrincipal? {
        // Enrollment uses 256-bit random hex bearer values; a digest alone cannot prove entropy.
        guard Self.isDigest(credential) else { return nil }
        let digest = SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }
            .joined()
        for row in enrollments where !row.revoked {
            // Compare all digest bytes to avoid exposing the first mismatching byte.
            let different = zip(digest.utf8, row.credentialSHA256.utf8).reduce(UInt8(0)) {
                $0 | ($1.0 ^ $1.1)
            }
            if different == 0 {
                return SyncPrincipal(
                    serviceID: serviceID, libraryID: row.libraryID, deviceID: row.deviceID)
            }
        }
        return nil
    }
}

public struct ConfigurationAuthorizer: SyncAuthorizer {
    public let configurationURL: URL
    public let serviceID: UUID

    public init(configurationURL: URL, serviceID: UUID) {
        self.configurationURL = configurationURL
        self.serviceID = serviceID
    }

    public func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        let config = try HostConfiguration.read(configurationURL)
        guard config.serviceID == serviceID else { throw HostError.serviceChanged }
        return config.principal(for: bearerCredential)
    }
}
