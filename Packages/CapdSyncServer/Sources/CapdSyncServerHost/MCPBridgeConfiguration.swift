import CapdMCP
import CapdSync
import CryptoKit
import Foundation

/// Separate service-principal policy. It never enrolls a device in /v1/sync.
public struct MCPBridgeConfiguration: Decodable, Sendable {
    public let version: Int
    public let serviceID: UUID
    public let libraryID: UUID
    public let resource: String
    public let principalID: String
    public let credentialSHA256: String
    public let scopes: [String]
    public let writerDeviceID: UUID?
    public let revoked: Bool

    public static func read(_ url: URL) throws -> Self {
        let data = try MCPPrivateFile.read(url, maximumBytes: 8192)
        guard MCPJSONSafety.validate(data, maximumBytes: 8192),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: [
                "version", "serviceID", "libraryID", "resource", "principalID", "credentialSHA256",
                "scopes", "writerDeviceID", "revoked",
            ])
        else { throw HostError.invalidConfiguration }
        let result = try JSONDecoder().decode(Self.self, from: data)
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard result.version == 1, result.serviceID != zero, result.libraryID != zero,
            !result.principalID.isEmpty, result.principalID.utf8.count <= 128,
            result.principalID.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
            isDigest(result.credentialSHA256),
            Set(result.scopes).count == result.scopes.count,
            Set(result.scopes) == [MCPToolbox.readScope]
                || Set(result.scopes) == [MCPToolbox.readScope, MCPToolbox.writeScope],
            let resource = URL(string: result.resource), resource.scheme == "https",
            resource.host != nil,
            resource.user == nil, resource.password == nil, resource.path == "/mcp",
            resource.query == nil,
            resource.fragment == nil, result.resource.utf8.count <= 2048,
            !result.resource.contains("\r"), !result.resource.contains("\n"),
            !result.resource.contains("\"")
        else { throw HostError.invalidConfiguration }
        if result.scopes.contains(MCPToolbox.writeScope) {
            guard let id = result.writerDeviceID, id != zero else {
                throw HostError.invalidConfiguration
            }
        } else if result.writerDeviceID != nil {
            throw HostError.invalidConfiguration
        }
        return result
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func validateBinding(serviceID: UUID, sync: HostConfiguration) throws {
        guard self.serviceID == serviceID, sync.serviceID == serviceID,
            !sync.enrollments.contains(where: {
                $0.credentialSHA256 == credentialSHA256 || $0.deviceID == writerDeviceID
            })
        else { throw HostError.invalidConfiguration }
    }

    func authorize(_ bearer: String, serviceID: UUID, sync: HostConfiguration) throws -> MCPGrant? {
        try validateBinding(serviceID: serviceID, sync: sync)
        guard !revoked, Self.isDigest(bearer) else { return nil }
        let digest = SHA256.hash(data: Data(bearer.utf8)).map { String(format: "%02x", $0) }
            .joined()
        let mismatch = zip(digest.utf8, credentialSHA256.utf8).reduce(UInt8(0)) {
            $0 | ($1.0 ^ $1.1)
        }
        guard mismatch == 0 else { return nil }
        return MCPGrant(
            issuer: MCPGrant.bridgeIssuer, audience: resource, subject: principalID,
            binding: SyncLibraryBinding(libraryID: libraryID, serviceID: serviceID),
            scopes: Set(scopes), deviceID: writerDeviceID, expiresAt: Date().addingTimeInterval(30))
    }
}

/// Only used after fresh policy verification on the authority queue for this one request.
struct MCPBridgeRequestVerifier: MCPTokenVerifier {
    let bearer: String
    let grant: MCPGrant
    func verify(_ bearer: String) throws -> MCPGrant {
        guard bearer == self.bearer else { throw MCPFailure.forbidden }
        return grant
    }
}
