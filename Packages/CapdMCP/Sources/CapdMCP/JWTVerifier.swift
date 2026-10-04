import CapdSync
import CryptoKit
import Foundation

/// Exact OAuth subject + client identity approved by the runtime owner.
public struct MCPJWTPrincipal: Hashable, Sendable {
    public let subject: String
    public let clientID: String
    public init(subject: String, clientID: String) {
        self.subject = subject
        self.clientID = clientID
    }
}
public struct MCPJWTAuthorization: Sendable {
    public let scopes: Set<String>
    public let deviceID: UUID?
    public init(scopes: Set<String>, deviceID: UUID? = nil) {
        self.scopes = scopes
        self.deviceID = deviceID
    }
}

/// Trusted configuration only. Keys are P-256 X9.63 public keys, never bearer credentials.
/// This narrow ES256 profile is not a general-purpose JWT/OIDC implementation or OAuth issuer.
public struct MCPJWTPolicy: Sendable {
    public let issuer: String
    public let audience: String
    public let binding: SyncLibraryBinding
    public let keys: [String: Data]
    public let principals: [MCPJWTPrincipal: MCPJWTAuthorization]
    public let revokedTokenIDs: Set<String>
    public let maximumLifetime: Int64
    public init(
        issuer: String, audience: String, binding: SyncLibraryBinding, keys: [String: Data],
        principals: [MCPJWTPrincipal: MCPJWTAuthorization], revokedTokenIDs: Set<String> = [],
        maximumLifetime: Int64 = 3600
    ) throws {
        for value in [issuer, audience] {
            guard let u = URL(string: value), u.scheme == "https", u.host != nil,
                u.user == nil, u.password == nil, u.fragment == nil,
                !value.contains("\r"), !value.contains("\n"), !value.contains("\"")
            else { throw MCPFailure.forbidden }
        }
        guard (1...3600).contains(maximumLifetime), (1...8).contains(keys.count),
            principals.count <= 100, revokedTokenIDs.count <= 10_000
        else { throw MCPFailure.forbidden }
        for (id, key) in keys {
            guard !id.isEmpty, id.utf8.count <= 128, key.count == 65 else {
                throw MCPFailure.forbidden
            }
            _ = try P256.Signing.PublicKey(x963Representation: key)
        }
        let allowed: Set<String> = [MCPToolbox.readScope, MCPToolbox.writeScope]
        let zeroDeviceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        var writerDevices: Set<UUID> = []
        for (p, a) in principals {
            guard !p.subject.isEmpty, p.subject.utf8.count <= 256, !p.clientID.isEmpty,
                p.clientID.utf8.count <= 256,
                a.scopes.isSubset(of: allowed),
                !a.scopes.contains(MCPToolbox.writeScope)
                    || (a.scopes.contains(MCPToolbox.readScope)
                        && a.deviceID.map { $0 != zeroDeviceID } == true)
            else { throw MCPFailure.forbidden }
            if a.scopes.contains(MCPToolbox.writeScope), let deviceID = a.deviceID {
                guard writerDevices.insert(deviceID).inserted else { throw MCPFailure.forbidden }
            }
        }
        guard revokedTokenIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw MCPFailure.forbidden
        }
        self.issuer = issuer
        self.audience = audience
        self.binding = binding
        self.keys = keys
        self.principals = principals
        self.revokedTokenIDs = revokedTokenIDs
        self.maximumLifetime = maximumLifetime
    }
}

/// Called on every verification. Implementations must atomically supply current policy, fail
/// closed when unavailable/stale, and serialize updates; do not cache a grant in an MCP session.
public protocol MCPJWTPolicyProvider: Sendable {
    func currentPolicy() throws -> MCPJWTPolicy
}

/// Verification-only adapter: no token minting, networking, discovery, or persistent keys.
/// The approved OAuth issuer must issue this exact profile (at+jwt, ES256, signed capd binding).
/// An RS256/opaque-token issuer needs a separately reviewed verifier; there is no fallback.
public struct MCPJWTVerifier: MCPTokenVerifier {
    private let provider: any MCPJWTPolicyProvider
    private let clock: @Sendable () -> Date
    public init(
        provider: any MCPJWTPolicyProvider, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.clock = clock
    }
    public func verify(_ bearer: String) throws -> MCPGrant {
        guard bearer.utf8.count <= 8192 else { throw MCPFailure.forbidden }
        let parts = bearer.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let h = Self.decode(parts[0], maximum: 1024),
            let c = Self.decode(parts[1], maximum: 4096),
            let signature = Self.decode(parts[2], maximum: 64),
            signature.count == 64, boundedJSON(h), boundedJSON(c),
            let header = try? JSONDecoder().decode(JSONValue.self, from: h).object,
            let claims = try? JSONDecoder().decode(JSONValue.self, from: c).object,
            Set(header.keys) == ["alg", "typ", "kid"], header["alg"] == .string("ES256"),
            header["typ"] == .string("at+jwt"), let kid = header["kid"]?.string,
            kid.utf8.count <= 128
        else { throw MCPFailure.forbidden }
        let policy = try provider.currentPolicy()
        guard let key = policy.keys[kid],
            try P256.Signing.PublicKey(x963Representation: key).isValidSignature(
                P256.Signing.ECDSASignature(rawRepresentation: signature),
                for: Data("\(parts[0]).\(parts[1])".utf8))
        else { throw MCPFailure.forbidden }
        guard claims["iss"] == .string(policy.issuer),
            claims["aud"] == .string(policy.audience)
                || claims["aud"] == .array([.string(policy.audience)]),
            let subject = claims["sub"]?.string, subject.utf8.count <= 256,
            let client = claims["client_id"]?.string, client.utf8.count <= 256,
            let authorization = policy.principals[
                MCPJWTPrincipal(subject: subject, clientID: client)],
            let jti = claims["jti"]?.string, !jti.isEmpty, jti.utf8.count <= 256,
            !policy.revokedTokenIDs.contains(jti),
            let library = claims["capd_library_id"]?.string.flatMap(UUID.init(uuidString:)),
            library == policy.binding.libraryID,
            let service = claims["capd_service_id"]?.string.flatMap(UUID.init(uuidString:)),
            service == policy.binding.serviceID,
            let issued = Self.time(claims["iat"]), let expiry = Self.time(claims["exp"]),
            expiry > issued, expiry - issued <= policy.maximumLifetime,
            let scope = claims["scope"]?.string, scope.utf8.count <= 64,
            claims["device_id"] == nil
        else { throw MCPFailure.forbidden }
        let now = clock().timeIntervalSince1970
        guard now.isFinite, Double(issued) <= now, Double(expiry) > now else {
            throw MCPFailure.forbidden
        }
        if let nbf = claims["nbf"] {
            guard let validFrom = Self.time(nbf), Double(validFrom) <= now, validFrom < expiry
            else { throw MCPFailure.forbidden }
        }
        // Only ASCII-space OAuth scope separators; no normalization or implicit scope upgrades.
        let scopes = Set(scope.split(separator: " ").map(String.init))
        guard !scopes.isEmpty, scopes.isSubset(of: [MCPToolbox.readScope, MCPToolbox.writeScope]),
            scopes.isSubset(of: authorization.scopes)
        else { throw MCPFailure.forbidden }
        return MCPGrant(
            issuer: policy.issuer, audience: policy.audience, subject: subject,
            binding: policy.binding,
            scopes: scopes,
            deviceID: scopes.contains(MCPToolbox.writeScope) ? authorization.deviceID : nil,
            expiresAt: Date(timeIntervalSince1970: Double(expiry)), clientID: client)
    }
    private static func time(_ value: JSONValue?) -> Int64? {
        guard let v = value?.integer, (0...9_007_199_254_740_991).contains(v) else { return nil }
        return v
    }
    private static func decode(_ value: Substring, maximum: Int) -> Data? {
        guard !value.isEmpty, value.utf8.count <= (maximum * 4 + 2) / 3,
            value.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 45 || $0 == 95
            })
        else { return nil }
        let string = String(value).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
            of: "_", with: "/")
        guard
            let data = Data(
                base64Encoded: string + String(repeating: "=", count: (4 - string.count % 4) % 4)),
            data.count <= maximum,
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                == String(value)
        else { return nil }
        return data
    }
}
