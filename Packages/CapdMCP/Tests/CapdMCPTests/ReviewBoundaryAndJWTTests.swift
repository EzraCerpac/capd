import CapdSync
import CryptoKit
import Foundation
import XCTest

@testable import CapdMCP

final class ReviewBoundaryAndJWTTests: XCTestCase {
    func testJWTPolicyRequiresDistinctDevicesAcrossWriters() throws {
        let key = P256.Signing.PrivateKey()
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let principal = MCPJWTPrincipal(subject: "subject-a", clientID: "client-a")
        let sharedDevice = UUID()
        let writer = MCPJWTAuthorization(
            scopes: [MCPToolbox.readScope, MCPToolbox.writeScope], deviceID: sharedDevice)
        func policy(_ principals: [MCPJWTPrincipal: MCPJWTAuthorization]) throws -> MCPJWTPolicy {
            try MCPJWTPolicy(
                issuer: "https://auth.example.invalid",
                audience: "https://capd.example.invalid/mcp",
                binding: binding, keys: ["synthetic-key": key.publicKey.x963Representation],
                principals: principals)
        }
        for other in [
            MCPJWTPrincipal(subject: "subject-b", clientID: "client-a"),
            MCPJWTPrincipal(subject: "subject-a", clientID: "client-b"),
        ] {
            XCTAssertThrowsError(try policy([principal: writer, other: writer]))
            let independent = MCPJWTAuthorization(scopes: writer.scopes, deviceID: UUID())
            XCTAssertNoThrow(try policy([principal: writer, other: independent]))
            let reader = MCPJWTAuthorization(scopes: [MCPToolbox.readScope], deviceID: sharedDevice)
            XCTAssertNoThrow(try policy([principal: writer, other: reader]))
            XCTAssertNoThrow(try policy([principal: reader, other: reader]))
        }
    }
    func testBearerSchemeIsCaseInsensitiveAndTokenRemainsCaseSensitive() throws {
        let fixture = try MCPTests.Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let boundary = try MCPHTTPBoundary(
            toolbox: fixture.toolbox, verifier: MCPTests.Verifier(grant: fixture.grant),
            issuer: fixture.grant.issuer, resource: fixture.grant.audience,
            metadataURL: "https://capd.example.invalid/.well-known/oauth-protected-resource/mcp",
            origins: [], binding: fixture.binding)
        let body = try JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .number(1),
                "method": .string("tools/list"), "params": .object([:]),
            ]))

        for authorization in ["bearer synthetic", "BEARER  synthetic", "bEaReR    synthetic"] {
            let response = boundary.handle(
                MCPHTTPRequest(
                    method: "POST", path: "/mcp",
                    headers: [
                        "Authorization": authorization,
                        "Accept": "application/json, text/event-stream",
                        "Content-Type": "application/json",
                        "MCP-Protocol-Version": "2025-11-25",
                    ], body: body))
            XCTAssertEqual(response.status, 200, "authorization: \(authorization)")
        }

        for authorization in ["Bearer", "Bearer ", "Bearer    ", "Bearer\tsynthetic"] {
            XCTAssertNil(MCPHTTPBoundary.bearerCredential(authorization))
        }
        XCTAssertEqual(MCPHTTPBoundary.bearerCredential("Bearer synthetic "), "synthetic ")

        let wrongScheme = boundary.handle(
            MCPHTTPRequest(
                method: "POST", path: "/mcp",
                headers: [
                    "Authorization": "Token synthetic",
                    "Accept": "application/json, text/event-stream",
                    "Content-Type": "application/json",
                    "MCP-Protocol-Version": "2025-11-25",
                ], body: body))
        XCTAssertEqual(wrongScheme.status, 401)

        let changedToken = boundary.handle(
            MCPHTTPRequest(
                method: "POST", path: "/mcp",
                headers: [
                    "Authorization": "bEaReR SYNTHETIC",
                    "Accept": "application/json, text/event-stream",
                    "Content-Type": "application/json",
                    "MCP-Protocol-Version": "2025-11-25",
                ], body: body))
        XCTAssertEqual(changedToken.status, 401)
    }

    func testAcceptRequiresPositiveValidQualityForBothMediaTypes() throws {
        let f = try MCPTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let boundary = try MCPHTTPBoundary(
            toolbox: f.toolbox, verifier: MCPTests.Verifier(grant: f.grant),
            issuer: f.grant.issuer, resource: f.grant.audience,
            metadataURL: "https://capd.example.invalid/metadata", origins: [], binding: f.binding)
        let body = try JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/list"),
            ]))
        let cases: [(String, Int)] = [
            ("application/json;q=0, text/event-stream", 406),
            ("application/json, text/event-stream;q=0.000", 406),
            ("application/json;q=invalid, text/event-stream", 406),
            ("application/json;q=1.001, text/event-stream", 406),
            ("application/json;q=-1, text/event-stream", 406),
            ("application/json;q=0.1234, text/event-stream", 406),
            ("application/json;q=0.5;q=1, text/event-stream", 406),
            ("application/json;q=0, text/event-stream, */*;q=1", 406),
            ("application/*;q=0.5, application/json;q=0, text/event-stream", 406),
            ("application/json;q=0.001, text/event-stream;q=1.000", 200),
            ("Application/JSON; Q=0.5, text/event-stream", 200),
            ("application/json, text/event-stream", 200),
            ("application/*;q=0.5, text/*;q=0.5", 200),
            ("*/*;q=0, application/json;q=0.5, text/event-stream;q=1", 200),
        ]
        for (accept, expected) in cases {
            let response = boundary.handle(
                MCPHTTPRequest(
                    method: "POST", path: "/mcp",
                    headers: [
                        "Authorization": "Bearer synthetic", "Accept": accept,
                        "Content-Type": "application/json", "MCP-Protocol-Version": "2025-11-25",
                    ], body: body))
            XCTAssertEqual(response.status, expected, accept)
        }
    }

    func testGenericHTTPVerifierCannotReserveZeroWriterDevice() throws {
        let f = try MCPTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let arguments = f.create()
        let body = try JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
                "params": .object([
                    "name": .string("create_capture"), "arguments": .object(arguments),
                ]),
            ]))
        func call(device: UUID) throws -> Object {
            let grant = MCPGrant(
                issuer: f.grant.issuer, audience: f.grant.audience, subject: f.grant.subject,
                binding: f.binding, scopes: f.grant.scopes, deviceID: device,
                expiresAt: f.grant.expiresAt)
            let boundary = try MCPHTTPBoundary(
                toolbox: f.toolbox, verifier: MCPTests.Verifier(grant: grant),
                issuer: grant.issuer, resource: grant.audience,
                metadataURL: "https://capd.example.invalid/metadata", origins: [],
                binding: f.binding)
            let response = boundary.handle(
                MCPHTTPRequest(
                    method: "POST", path: "/mcp",
                    headers: [
                        "Authorization": "Bearer synthetic",
                        "Accept": "application/json, text/event-stream",
                        "Content-Type": "application/json", "MCP-Protocol-Version": "2025-11-25",
                    ], body: body))
            XCTAssertEqual(response.status, 200)
            return try XCTUnwrap(
                JSONDecoder().decode(JSONValue.self, from: response.body)
                    .object?["result"]?.object)
        }
        XCTAssertEqual(try call(device: zero)["isError"], .bool(true))
        XCTAssertTrue(try f.server.baseline().captures.isEmpty)
        XCTAssertTrue(try f.server.baseline().deviceSequences.isEmpty)
        XCTAssertEqual(try f.store.nextSequence(deviceID: zero), 1)
        XCTAssertEqual(try call(device: f.device)["isError"], .bool(false))
        XCTAssertEqual(try call(device: f.device)["isError"], .bool(false))
        XCTAssertEqual(try f.server.baseline().deviceSequences, [f.device: 1])
    }

    func testJWTPolicyRejectsZeroDeviceForWriter() throws {
        let zeroDeviceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let key = P256.Signing.PrivateKey()
        let principal = MCPJWTPrincipal(subject: "synthetic-subject", clientID: "synthetic-client")
        let writer = MCPJWTAuthorization(
            scopes: [MCPToolbox.readScope, MCPToolbox.writeScope], deviceID: zeroDeviceID)

        XCTAssertThrowsError(
            try MCPJWTPolicy(
                issuer: "https://auth.example.invalid",
                audience: "https://capd.example.invalid/mcp",
                binding: binding, keys: ["synthetic-key": key.publicKey.x963Representation],
                principals: [principal: writer]))
    }
}
