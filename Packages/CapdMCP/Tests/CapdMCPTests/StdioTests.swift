import CapdSync
import Darwin
import Foundation
import XCTest

@testable import CapdMCP

final class StdioTests: XCTestCase {
    struct Fixture {
        let root: URL
        let key: URL
        let token = String(repeating: "d", count: 64)
        init() throws {
            root = try canonicalTemporaryDirectory()
                .appendingPathComponent("capd-stdio-\(UUID())")
            key = root.appendingPathComponent("bridge-token")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(token.utf8).write(to: key)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: key.path)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func line(_ method: String = "tools/list", params: [String: Any] = [:], id: Int? = 7) throws
            -> Data
        {
            var value: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            if let id { value["id"] = id }
            return try JSONSerialization.data(withJSONObject: value)
        }
    }
    func testFixedEndpointDerivedHeadersAndExactWriteIdentity() throws {
        let f = try Fixture()
        defer { f.clean() }
        let identity = UUID().uuidString
        let line = try f.line(
            "tools/call",
            params: [
                "name": "create_capture", "arguments": ["operation_id": identity, "sequence": 42],
                "_meta": [
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientCapabilities": [:],
                ],
            ])
        let reply = Data("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"isError\":false}}".utf8)
        let expectedToken = f.token
        let bridge = try MCPStdioBridge(
            credentialURL: f.key, socketURL: f.root.appendingPathComponent("authority.sock")
        ) { request in
            XCTAssertEqual(request.url?.absoluteString, "http://capd.local/mcp")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.httpBody, line)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"), "Bearer \(expectedToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2026-07-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Method"), "tools/call")
            XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Name"), "create_capture")
            return MCPHTTPResponse(status: 200, body: reply)
        }
        XCTAssertEqual(bridge.forward(line), reply)
        XCTAssertEqual(bridge.forward(line), reply)  // No operation/sequence renumbering during exact retry.
    }
    func testInvalidFramesAndUnknownToolsNeverForward() throws {
        let f = try Fixture()
        defer { f.clean() }
        let bridge = try MCPStdioBridge(
            credentialURL: f.key, socketURL: f.root.appendingPathComponent("authority.sock")
        ) { _ in
            XCTFail("Invalid frame forwarded")
            throw MCPFailure.unavailable
        }
        let frames = [
            Data("{\"jsonrpc\":\"2.0\",\"id\":7,\"id\":8,\"method\":\"tools/list\"}".utf8),
            Data(repeating: 32, count: 65_537), try f.line("resources/read"),
            try f.line("tools/call", params: ["name": "delete_capture"]),
            try f.line(
                "tools/list",
                params: [
                    "_meta": ["io.modelcontextprotocol/protocolVersion": "bad\r\nInjected: secret"]
                ]),
        ]
        for frame in frames {
            let output = try XCTUnwrap(bridge.forward(frame))
            XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("error"))
            XCTAssertFalse(String(decoding: output, as: UTF8.self).contains(f.token))
        }
    }
    func testLostOrInvalidReplyIsSafeAndNeverTriggersOAuth() throws {
        let f = try Fixture()
        defer { f.clean() }
        let line = try f.line(
            "tools/call",
            params: [
                "name": "edit_capture",
                "arguments": ["operation_id": UUID().uuidString, "sequence": 2],
            ])
        for status in [401, 403, 504, 302] {
            let fake = MCPHTTPResponse(
                status: status,
                headers: [
                    "Location": "https://evil.example.invalid", "WWW-Authenticate": "token-secret",
                ], body: Data("token-secret".utf8))
            let bridge = try MCPStdioBridge(
                credentialURL: f.key, socketURL: f.root.appendingPathComponent("authority.sock")
            ) { _ in fake }
            let text = String(decoding: try XCTUnwrap(bridge.forward(line)), as: UTF8.self)
            XCTAssertFalse(text.contains("token-secret"))
            XCTAssertFalse(text.contains("mcp/www_authenticate"))
            XCTAssertTrue(text.contains("without renumbering"))
        }
        let lost = try MCPStdioBridge(
            credentialURL: f.key, socketURL: f.root.appendingPathComponent("authority.sock")
        ) { _ in throw MCPFailure.unavailable }
        let output = String(decoding: try XCTUnwrap(lost.forward(line)), as: UTF8.self)
        XCTAssertTrue(output.contains("identical operation_id"))
        let wrongID = try MCPStdioBridge(
            credentialURL: f.key, socketURL: f.root.appendingPathComponent("authority.sock")
        ) { _ in
            MCPHTTPResponse(
                status: 200, body: Data("{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{}}".utf8))
        }
        XCTAssertTrue(
            String(decoding: try XCTUnwrap(wrongID.forward(line)), as: UTF8.self).contains("error"))
    }
    func testPrivateFileRejectsModesSymlinksAndOversize() throws {
        let f = try Fixture()
        defer { f.clean() }
        XCTAssertEqual(try MCPPrivateFile.read(f.key, maximumBytes: 66), Data(f.token.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.key.path)
        XCTAssertThrowsError(try MCPPrivateFile.read(f.key, maximumBytes: 66))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.key.path)
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.key)
        XCTAssertThrowsError(try MCPPrivateFile.read(link, maximumBytes: 66))
        XCTAssertThrowsError(try MCPPrivateFile.read(f.key, maximumBytes: 10))
        let directoryLink = f.root.appendingPathComponent("dir-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: f.root)
        XCTAssertThrowsError(
            try MCPPrivateFile.read(
                directoryLink.appendingPathComponent("bridge-token"), maximumBytes: 66))
    }
    func testSocketPathRequiresPrivateDirectoryAndRejectsPlaceholderOrSymlink() throws {
        let f = try Fixture()
        defer { f.clean() }
        let socket = f.root.appendingPathComponent("authority.sock")
        XCTAssertNoThrow(try MCPUnixSocket.validatePath(socket, mustExist: false))
        XCTAssertThrowsError(try MCPUnixSocket.validatePath(socket, mustExist: true))
        try Data().write(to: socket)
        XCTAssertThrowsError(try MCPUnixSocket.validatePath(socket, mustExist: false))
        XCTAssertThrowsError(try MCPUnixSocket.validatePath(socket, mustExist: true))
        try FileManager.default.removeItem(at: socket)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.path)
        XCTAssertThrowsError(try MCPUnixSocket.validatePath(socket, mustExist: false))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.root.path)
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
        XCTAssertThrowsError(
            try MCPUnixSocket.validatePath(
                link.appendingPathComponent("authority.sock"), mustExist: false))
    }

    func testFramingBoundsAndPartialLastLine() throws {
        let f = try Fixture()
        defer { f.clean() }
        let input = f.root.appendingPathComponent("input")
        try Data("first\nsecond".utf8).write(to: input)
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let reader = MCPFrameReader(input: handle)
        XCTAssertEqual(try reader.next(), Data("first".utf8))
        XCTAssertEqual(try reader.next(), Data("second".utf8))
        XCTAssertNil(try reader.next())
        try Data(repeating: 65, count: 65_537).write(to: input)
        let other = try FileHandle(forReadingFrom: input)
        defer { try? other.close() }
        XCTAssertThrowsError(try MCPFrameReader(input: other).next())
    }
    func testNotificationsDoNotEmitUnsolicitedResponses() throws {
        let f = try Fixture()
        defer { f.clean() }
        let bridge = try MCPStdioBridge(
            credentialURL: f.key, socketURL: f.root.appendingPathComponent("authority.sock")
        ) { _ in MCPHTTPResponse(status: 202) }
        XCTAssertNil(bridge.forward(try f.line("notifications/initialized", id: nil)))
    }
}

private func canonicalTemporaryDirectory() throws -> URL {
    guard let resolved = realpath("/tmp", nil) else {
        throw MCPFailure.unavailable
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}
