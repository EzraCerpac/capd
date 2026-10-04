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
