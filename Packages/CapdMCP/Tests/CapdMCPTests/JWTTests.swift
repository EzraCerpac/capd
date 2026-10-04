import CapdSync
import CryptoKit
import Foundation
import XCTest

@testable import CapdMCP

final class JWTTests: XCTestCase {
    /// Ephemeral synthetic test policy; never shipped as a production provider.
    final class Provider: MCPJWTPolicyProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var value: MCPJWTPolicy
        init(_ value: MCPJWTPolicy) { self.value = value }
        func currentPolicy() throws -> MCPJWTPolicy { lock.withLock { value } }
        func replace(_ value: MCPJWTPolicy) { lock.withLock { self.value = value } }
    }
    struct Fixture {
        let f: MCPTests.Fixture
        let key = P256.Signing.PrivateKey()
        let now = Date()
        init() throws { f = try MCPTests.Fixture() }
        func policy(scopes: Set<String> = ["capd:read", "capd:write"], revoked: Set<String> = [])
            throws -> MCPJWTPolicy
        {
            try MCPJWTPolicy(
                issuer: f.grant.issuer, audience: f.grant.audience, binding: f.binding,
                keys: ["synthetic-key": key.publicKey.x963Representation],
                principals: [
                    MCPJWTPrincipal(subject: "synthetic-subject", clientID: "synthetic-client"):
                        MCPJWTAuthorization(scopes: scopes, deviceID: f.device)
                ], revokedTokenIDs: revoked)
        }
        var claims: Object {
            [
                "iss": .string(f.grant.issuer), "aud": .string(f.grant.audience),
                "sub": .string("synthetic-subject"),
                "client_id": .string("synthetic-client"), "jti": .string("synthetic-token"),
                "capd_library_id": .string(f.binding.libraryID.uuidString),
                "capd_service_id": .string(f.binding.serviceID.uuidString),
                "iat": .number(Decimal(Int64(now.timeIntervalSince1970) - 1)),
                "exp": .number(Decimal(Int64(now.timeIntervalSince1970) + 600)),
                "scope": .string("capd:read capd:write"),
            ]
        }
        func token(
            _ claims: Object? = nil,
            header: Object = [
                "alg": .string("ES256"), "typ": .string("at+jwt"), "kid": .string("synthetic-key"),
            ], signingKey: P256.Signing.PrivateKey? = nil, rawClaims: Data? = nil
        ) throws -> String {
            let h = try JSONEncoder().encode(JSONValue.object(header))
            let c = try rawClaims ?? JSONEncoder().encode(JSONValue.object(claims ?? self.claims))
            let input = "\(Self.encode(h)).\(Self.encode(c))"
            let signature = try (signingKey ?? key).signature(for: Data(input.utf8))
                .rawRepresentation
            return "\(input).\(Self.encode(signature))"
        }
        static func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
    }
    func testSignedHTTPReadWriteAndFreshRevocation() throws {
        let x = try Fixture()
        defer { try? FileManager.default.removeItem(at: x.f.directory) }
        let provider = try Provider(x.policy())
        let verifier = MCPJWTVerifier(provider: provider)
        let boundary = try MCPHTTPBoundary(
            toolbox: x.f.toolbox, verifier: verifier, issuer: x.f.grant.issuer,
            resource: x.f.grant.audience,
            metadataURL: "https://capd.example.invalid/.well-known/oauth-protected-resource/mcp",
            origins: [], binding: x.f.binding)
        let token = try x.token()
        func request(_ name: String, _ args: Object = [:]) throws -> MCPHTTPResponse {
            let body = try JSONEncoder().encode(
                JSONValue.object([
                    "jsonrpc": .string("2.0"), "id": .number(1),
                    "method": .string("tools/call"),
                    "params": .object(["name": .string(name), "arguments": .object(args)]),
                ]))
            return boundary.handle(
                MCPHTTPRequest(
                    method: "POST", path: "/mcp",
                    headers: [
                        "Authorization": "Bearer \(token)",
                        "Accept": "application/json, text/event-stream",
                        "Content-Type": "application/json", "MCP-Protocol-Version": "2025-11-25",
                    ], body: body))
        }
        let id = UUID()
        let created = try request("create_capture", x.f.create(id: id))
        XCTAssertEqual(created.status, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: created.body).object?["result"]?.object?[
                "isError"], .bool(false))
        let recent = try request("list_recent")
        XCTAssertEqual(recent.status, 200)
        XCTAssertTrue(
            String(decoding: recent.body, as: UTF8.self).contains("untrusted_capture_content"))
        let edited = try request(
            "edit_capture",
            [
                "operation_id": .string(UUID().uuidString), "sequence": .number(2),
                "id": .string(id.uuidString), "base_revision": .number(1),
                "note": .string("synthetic signed edit"), "rating": .number(4),
            ])
        XCTAssertEqual(edited.status, 200)
        XCTAssertEqual(try x.f.store.capture(id: id)?.note, "synthetic signed edit")
        XCTAssertTrue(
            x.f.toolbox.definitions(grant: try verifier.verify(token)).allSatisfy {
                $0.object?["securitySchemes"] != nil
            })
        try provider.replace(x.policy(scopes: ["capd:read"]))
        // Existing write token now fails; it is not silently reduced or session-cached.
        XCTAssertEqual(try request("list_recent").status, 401)
        try provider.replace(x.policy(revoked: ["synthetic-token"]))
        XCTAssertEqual(try request("list_recent").status, 401)
        XCTAssertEqual(try x.f.server.baseline().deviceSequences[x.f.device], 2)
    }
    func testRejectsSignatureHeaderClaimsAndEncodingAttacks() throws {
        let x = try Fixture()
        defer { try? FileManager.default.removeItem(at: x.f.directory) }
        let verifier = MCPJWTVerifier(provider: try Provider(x.policy()), clock: { x.now })
        XCTAssertThrowsError(try x.policy(scopes: ["capd:write"]))
        XCTAssertNoThrow(try verifier.verify(x.token()))
        XCTAssertThrowsError(try verifier.verify(x.token(signingKey: P256.Signing.PrivateKey())))
        for (field, value): (String, JSONValue) in [
            ("iss", .string("https://wrong.invalid")), ("aud", .string("https://wrong.invalid")),
            ("aud", .array([.string(x.f.grant.audience), .string("https://extra.invalid")])),
            ("sub", .string("unapproved")), ("client_id", .string("other-client")),
            ("capd_library_id", .string(UUID().uuidString)),
            ("capd_service_id", .string(UUID().uuidString)),
            ("scope", .string("capd:read calendar:write")),
            ("scope", .string("capd:read\tcapd:write")),
            ("device_id", .string(UUID().uuidString)), ("jti", .string("")),
            ("exp", .number(Decimal(Int64(x.now.timeIntervalSince1970) - 1))),
            ("iat", .number(Decimal(Int64(x.now.timeIntervalSince1970) + 10))),
            ("nbf", .number(Decimal(Int64(x.now.timeIntervalSince1970) + 10))),
            ("exp", .number(Decimal(Int64(x.now.timeIntervalSince1970) + 4000))),
            ("iat", .string("0")), ("iat", .bool(true)), ("iat", .number(Decimal(string: "1.5")!)),
        ] {
            var claims = x.claims
            claims[field] = value
            XCTAssertThrowsError(try verifier.verify(x.token(claims)), field)
        }
        for field in [
            "iss", "aud", "sub", "client_id", "capd_library_id", "capd_service_id", "scope", "jti",
            "exp", "iat",
        ] {
            var claims = x.claims
            claims.removeValue(forKey: field)
            XCTAssertThrowsError(try verifier.verify(x.token(claims)), field)
        }
        for header: Object in [
            ["alg": .string("none"), "typ": .string("at+jwt"), "kid": .string("synthetic-key")],
            ["alg": .string("HS256"), "typ": .string("at+jwt"), "kid": .string("synthetic-key")],
            ["alg": .string("ES256"), "typ": .string("JWT"), "kid": .string("synthetic-key")],
            ["alg": .string("ES256"), "typ": .string("at+jwt"), "kid": .string("unknown")],
            [
                "alg": .string("ES256"), "typ": .string("at+jwt"), "kid": .string("synthetic-key"),
                "jku": .string("https://attacker.invalid"),
            ],
        ] {
            XCTAssertThrowsError(try verifier.verify(x.token(header: header)))
        }
        let c = try JSONEncoder().encode(JSONValue.object(x.claims))
        let duplicate = Data(
            ("{\"sub\":\"synthetic-subject\"," + String(decoding: c, as: UTF8.self).dropFirst())
                .utf8)
        XCTAssertThrowsError(try verifier.verify(x.token(rawClaims: duplicate)))
        let token = try x.token()
        XCTAssertThrowsError(try verifier.verify(token + "="))
        XCTAssertThrowsError(try verifier.verify(String(repeating: "x", count: 8193)))
        XCTAssertThrowsError(try verifier.verify(token + ".extra"))
        var claims = x.claims
        claims["scope"] = .string("capd:read")
        let grant = try verifier.verify(x.token(claims))
        XCTAssertNil(grant.deviceID)
        XCTAssertEqual(grant.scopes, ["capd:read"])
    }
}
