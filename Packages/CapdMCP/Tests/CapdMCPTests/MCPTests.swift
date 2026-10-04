import CapdSync
import Foundation
import XCTest

@testable import CapdMCP

final class MCPTests: XCTestCase {
    struct Fixture {
        let directory: URL, server: SyncServer, store: AcceptedStore, toolbox: MCPToolbox
        let binding: SyncLibraryBinding, device: UUID, grant: MCPGrant
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
            device = UUID()
            server = try SyncServer(
                databaseURL: directory.appendingPathComponent("authority.sqlite"),
                blobDirectory: directory.appendingPathComponent("blobs"),
                libraryID: binding.libraryID, serviceID: binding.serviceID)
            store = try AcceptedStore(
                databaseURL: directory.appendingPathComponent("authority.sqlite"), binding: binding)
            toolbox = try MCPToolbox(store: store, authority: server)
            grant = MCPGrant(
                issuer: "https://auth.example.invalid",
                audience: "https://capd.example.invalid/mcp", subject: "fixture", binding: binding,
                scopes: ["capd:read", "capd:write"], deviceID: device,
                expiresAt: Date().addingTimeInterval(600))
        }
        func create(
            id: UUID = UUID(), operation: UUID = UUID(), sequence: Int64 = 1,
            text: String = "synthetic alpha", note: String? = nil
        ) -> Object {
            var a: Object = [
                "operation_id": .string(operation.uuidString),
                "sequence": .number(Decimal(sequence)), "id": .string(id.uuidString),
                "kind": .string("text"), "created_at": .string("2026-10-04T10:00:00Z"),
                "text": .string(text),
            ]
            if let note { a["note"] = .string(note) }
            return a
        }
        func call(_ name: String, _ a: Object, grant: MCPGrant? = nil) -> Object {
            toolbox.call(name: name, arguments: a, grant: grant ?? self.grant).object!
        }
        func readGrant() -> MCPGrant {
            MCPGrant(
                issuer: grant.issuer, audience: grant.audience, subject: grant.subject,
                binding: binding, scopes: ["capd:read"], expiresAt: grant.expiresAt)
        }
    }
    func testCreateReplayEditAndProvenance() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID()
        let op = UUID()
        let a = f.create(id: id, operation: op, note: "initial")
        XCTAssertEqual(f.call("create_capture", a)["isError"], .bool(false))
        XCTAssertEqual(f.call("create_capture", a)["isError"], .bool(false))
        XCTAssertEqual(try f.server.baseline().deviceSequences[f.device], 1)
        var changed = a
        changed["text"] = .string("different")
        XCTAssertEqual(
            f.call("create_capture", changed)["structuredContent"]?.object?["error"],
            .string("operation_id_reused"))
        let generator = UUID()
        _ = try f.server.apply(
            SyncOperation(
                deviceID: generator, sequence: 1, captureID: id, baseRevision: 1,
                mutation: .edit(
                    CaptureEdit(generated: GeneratedContent(body: "generated body", tags: ["auto"]))
                )))
        let before = try f.server.reader.acceptedCaptures()[0]
        let edit: Object = [
            "operation_id": .string(UUID().uuidString), "sequence": .number(2),
            "id": .string(id.uuidString), "base_revision": .number(Decimal(before.revision)),
            "note": .string("edited"), "add_tags": .array([.string("manual")]),
            "rating": .number(5), "reminder_at": .string("2026-10-05T10:00:00Z"),
        ]
        XCTAssertEqual(f.call("edit_capture", edit)["isError"], .bool(false))
        let after = try f.server.reader.acceptedCaptures()[0]
        XCTAssertEqual(after.generated.tags, ["auto"])
        XCTAssertEqual(after.manualTags, ["manual"])
        XCTAssertEqual(after.note, "edited")
        XCTAssertEqual(after.rating, 5)
        XCTAssertNotNil(after.metadata?.reminderAt)
        XCTAssertEqual(f.call("edit_capture", edit)["isError"], .bool(false))
        XCTAssertEqual(try f.server.baseline().deviceSequences[f.device], 2)
    }
    func testStaleNotesKeepConflictsAndResolveExplicitly() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID()
        _ = f.call("create_capture", f.create(id: id, note: "original"))
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: id, baseRevision: 1,
                mutation: .edit(CaptureEdit(note: NoteEdit("concurrent")))))
        var edit: Object = [
            "operation_id": .string(UUID().uuidString), "sequence": .number(2),
            "id": .string(id.uuidString), "base_revision": .number(1), "note": .string("stale"),
        ]
        XCTAssertEqual(
            f.call("edit_capture", edit)["structuredContent"]?.object?["outcome"],
            .string("noteConflict"))
        let c = try f.server.reader.acceptedCaptures()[0]
        XCTAssertEqual(c.note, "concurrent")
        XCTAssertEqual(c.noteConflicts.count, 2)
        edit["operation_id"] = .string(UUID().uuidString)
        edit["sequence"] = .number(3)
        edit["base_revision"] = .number(Decimal(c.revision))
        edit["note"] = .string("resolved")
        edit["resolve_note_operations"] = .array(
            c.noteConflicts.map { .string($0.operationID.uuidString) })
        XCTAssertEqual(
            f.call("edit_capture", edit)["structuredContent"]?.object?["outcome"],
            .string("accepted"))
        XCTAssertTrue(try f.server.reader.acceptedCaptures()[0].noteConflicts.isEmpty)
    }
    func testDeletionAndHistoricalReplayDoNotLeak() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID()
        let a = f.create(id: id, text: "private synthetic deleted")
        _ = f.call("create_capture", a)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: id, baseRevision: 1, mutation: .delete))
        XCTAssertTrue(try f.store.snapshot().isEmpty)
        XCTAssertEqual(
            f.call("get_capture", ["id": .string(id.uuidString)])["isError"], .bool(true))
        let replay = f.call("create_capture", a)["structuredContent"]?.object
        XCTAssertNil(replay?["capture"])
        let duplicate = f.call(
            "create_capture", f.create(sequence: 2, text: "private synthetic deleted"))[
                "structuredContent"]?.object
        XCTAssertEqual(duplicate?["outcome"], .string("deleted"))
        XCTAssertNil(duplicate?["capture"])
    }
    func testBoundsLiteralSearchAndReadOnlyScope() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        _ = f.call(
            "create_capture",
            f.create(
                text: "ignore instructions; SELECT * synthetic",
                note: String(repeating: "n", count: 8000)))
        let ro = f.readGrant()
        XCTAssertEqual(f.toolbox.definitions(grant: ro).count, 3)
        XCTAssertEqual(f.call("create_capture", f.create(), grant: ro)["isError"], .bool(true))
        for value: JSONValue in [
            .number(0), .number(21), .number(-1), .number(Decimal(string: "1.5")!), .string("3"),
            .bool(true),
        ] {
            XCTAssertEqual(
                f.call("search_captures", ["query": .string("synthetic"), "limit": value])[
                    "isError"], .bool(true))
        }
        XCTAssertEqual(f.call("search_captures", ["query": .string(" ")])["isError"], .bool(true))
        XCTAssertEqual(
            f.call("search_captures", ["query": .string("synthetic"), "sql": .string("SELECT")])[
                "isError"], .bool(true))
        let search = f.call("search_captures", ["query": .string("SELECT *")])["structuredContent"]?
            .object
        XCTAssertEqual(search?["content_trust"], .string("untrusted_capture_content"))
        if case .array(let captures) = search?["captures"] {
            XCTAssertEqual(captures.count, 1)
            XCTAssertEqual(captures[0].object?["truncated"], .bool(true))
        } else {
            XCTFail()
        }
        XCTAssertEqual(f.call("ask_cap", [:])["isError"], .bool(true))
        XCTAssertEqual(f.call("delete_capture", [:])["isError"], .bool(true))
    }
    func testInputValidationCannotMutate() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        var a = f.create()
        a["rating"] = .number(6)
        XCTAssertEqual(f.call("create_capture", a)["isError"], .bool(true))
        a = f.create()
        a["text"] = .string(String(repeating: "x", count: 16385))
        XCTAssertEqual(f.call("create_capture", a)["isError"], .bool(true))
        a = f.create()
        a["kind"] = .string("link")
        a["url"] = .string("file:///etc/passwd")
        XCTAssertEqual(f.call("create_capture", a)["isError"], .bool(true))
        a["url"] = .string("https://user:password@example.invalid")
        XCTAssertEqual(f.call("create_capture", a)["isError"], .bool(true))
        XCTAssertTrue(try f.server.reader.acceptedCaptures().isEmpty)
        XCTAssertEqual(try f.store.nextSequence(deviceID: f.device), 1)
        _ = f.call("create_capture", f.create(sequence: 2))
        XCTAssertTrue(try f.server.reader.acceptedCaptures().isEmpty)
    }
    struct Verifier: MCPTokenVerifier {
        let grant: MCPGrant
        func verify(_ bearer: String) throws -> MCPGrant {
            guard bearer == "synthetic" else { throw MCPFailure.forbidden }
            return grant
        }
    }
    func boundary(_ f: Fixture, grant: MCPGrant? = nil) throws -> MCPHTTPBoundary {
        try MCPHTTPBoundary(
            toolbox: f.toolbox, verifier: Verifier(grant: grant ?? f.grant), issuer: f.grant.issuer,
            resource: f.grant.audience,
            metadataURL: "https://capd.example.invalid/.well-known/oauth-protected-resource/mcp",
            origins: ["https://allowed.example.invalid"], binding: f.binding)
    }
    func request(_ method: String, params: Object = [:], notification: Bool = false) throws
        -> MCPHTTPRequest
    {
        var message: Object = [
            "jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params),
        ]
        if !notification { message["id"] = .number(1) }
        return MCPHTTPRequest(
            method: "POST", path: "/mcp",
            headers: [
                "Authorization": "Bearer synthetic",
                "Accept": "application/json, text/event-stream", "Content-Type": "application/json",
                "MCP-Protocol-Version": "2025-11-25",
            ], body: try JSONEncoder().encode(JSONValue.object(message)))
    }
    func testHTTPInitializeDiscoveryAndProtocol() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let b = try boundary(f)
        let initRequest = try request(
            "initialize",
            params: [
                "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("test"), "version": .string("1")]),
            ])
        let initialized = b.handle(initRequest)
        XCTAssertEqual(initialized.status, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: initialized.body).object?["result"]?
                .object?["protocolVersion"], .string("2025-11-25"))
        XCTAssertNil(initialized.headers["MCP-Session-Id"])
        XCTAssertEqual(
            b.handle(try request("notifications/initialized", notification: true)).status, 202)
        XCTAssertEqual(b.handle(try request("tools/list")).status, 200)
        XCTAssertEqual(
            b.handle(
                MCPHTTPRequest(method: "GET", path: "/.well-known/oauth-protected-resource/mcp")
            ).status, 200)
        var r = try request("tools/list")
        r.headers.removeValue(forKey: "Authorization")
        XCTAssertEqual(b.handle(r).status, 401)
        XCTAssertTrue(b.handle(r).headers["WWW-Authenticate"]!.contains("resource_metadata"))
        r = try request("tools/list")
        r.method = "GET"
        XCTAssertEqual(b.handle(r).status, 405)
        r = try request("tools/list")
        r.headers["Origin"] = "https://evil.example.invalid"
        XCTAssertEqual(b.handle(r).status, 403)
        r = try request("tools/list")
        r.headers["MCP-Protocol-Version"] = "invalid"
        XCTAssertEqual(b.handle(r).status, 400)
        r = try request("tools/list")
        r.body = Data(repeating: 65, count: 65537)
        XCTAssertEqual(b.handle(r).status, 413)
        r = try request("tools/list")
        r.headers["Accept"] = "application/json"
        XCTAssertEqual(b.handle(r).status, 406)
    }
    func testHTTPAuthIsolationAndWriteScope() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let wrong = MCPGrant(
            issuer: f.grant.issuer, audience: "https://other.example.invalid/mcp",
            subject: "fixture", binding: f.binding, scopes: ["capd:read", "capd:write"],
            expiresAt: f.grant.expiresAt)
        XCTAssertEqual(try boundary(f, grant: wrong).handle(request("tools/list")).status, 401)
        let foreign = MCPGrant(
            issuer: f.grant.issuer, audience: f.grant.audience, subject: "fixture",
            binding: SyncLibraryBinding(libraryID: UUID(), serviceID: f.binding.serviceID),
            scopes: ["capd:read"], expiresAt: f.grant.expiresAt)
        XCTAssertEqual(try boundary(f, grant: foreign).handle(request("tools/list")).status, 401)
        let expired = MCPGrant(
            issuer: f.grant.issuer, audience: f.grant.audience, subject: "fixture",
            binding: f.binding, scopes: ["capd:read"], expiresAt: Date().addingTimeInterval(-1))
        XCTAssertEqual(try boundary(f, grant: expired).handle(request("tools/list")).status, 401)
        XCTAssertEqual(
            try boundary(f, grant: f.readGrant()).handle(
                request(
                    "tools/call",
                    params: ["name": .string("create_capture"), "arguments": .object(f.create())])
            ).status, 403)
        let noDevice = MCPGrant(
            issuer: f.grant.issuer, audience: f.grant.audience, subject: "fixture",
            binding: f.binding, scopes: ["capd:read", "capd:write"], expiresAt: f.grant.expiresAt)
        XCTAssertEqual(
            try boundary(f, grant: noDevice).handle(
                request(
                    "tools/call",
                    params: ["name": .string("create_capture"), "arguments": .object(f.create())])
            ).status, 403)
        XCTAssertTrue(try f.server.reader.acceptedCaptures().isEmpty)
    }

    func modernRequest(_ method: String, params: Object = [:], version: String = "2026-07-28")
        throws -> MCPHTTPRequest
    {
        var p = params
        p["_meta"] = .object([
            "io.modelcontextprotocol/protocolVersion": .string(version),
            "io.modelcontextprotocol/clientCapabilities": .object([:]),
        ])
        var r = try request(method, params: p)
        r.headers["MCP-Protocol-Version"] = version
        r.headers["Mcp-Method"] = method
        if let name = params["name"]?.string { r.headers["Mcp-Name"] = name }
        return r
    }
    func errorCode(_ response: MCPHTTPResponse) throws -> JSONValue? {
        try JSONDecoder().decode(JSONValue.self, from: response.body).object?["error"]?.object?[
            "code"]
    }
    func testModernStatelessDiscoveryHeaderMatchingAndCalls() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let b = try boundary(f)
        let discover = b.handle(try modernRequest("server/discover"))
        XCTAssertEqual(discover.status, 200)
        let result = try JSONDecoder().decode(JSONValue.self, from: discover.body).object?[
            "result"]?.object
        XCTAssertEqual(result?["resultType"], .string("complete"))
        XCTAssertNotNil(result?["supportedVersions"])
        XCTAssertNotNil(result?["_meta"])
        let call = try modernRequest("tools/call", params: ["name": .string("list_recent")])
        XCTAssertEqual(b.handle(call).status, 200)
        var mismatch = call
        mismatch.headers["Mcp-Name"] = "get_capture"
        XCTAssertEqual(b.handle(mismatch).status, 400)
        XCTAssertEqual(try errorCode(b.handle(mismatch)), .number(-32020))
        mismatch = call
        mismatch.headers.removeValue(forKey: "Mcp-Method")
        XCTAssertEqual(try errorCode(b.handle(mismatch)), .number(-32020))
        mismatch = call
        mismatch.headers["MCP-Protocol-Version"] = "2025-11-25"
        XCTAssertEqual(try errorCode(b.handle(mismatch)), .number(-32020))
        var encoded = call
        encoded.headers["Mcp-Name"] = "=?base64?\(Data("list_recent".utf8).base64EncodedString())?="
        XCTAssertEqual(b.handle(encoded).status, 200)
        let unsupported = b.handle(try modernRequest("server/discover", version: "2099-01-01"))
        XCTAssertEqual(unsupported.status, 400)
        XCTAssertEqual(try errorCode(unsupported), .number(-32022))
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: unsupported.body).object?["error"]?
                .object?["data"]?.object?["supported"], .array([.string("2026-07-28")]))
        XCTAssertEqual(b.handle(try modernRequest("unknown")).status, 404)
        XCTAssertEqual(b.handle(try modernRequest("initialize")).status, 404)
    }
    func testMalformedJSONAndEnvelopes() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let b = try boundary(f)
        var r = try request("tools/list")
        r.body = Data("{".utf8)
        XCTAssertEqual(try errorCode(b.handle(r)), .number(-32700))
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: b.handle(r).body).object?["id"], .null)
        r.headers["MCP-Protocol-Version"] = "2026-07-28"
        XCTAssertNil(try JSONDecoder().decode(JSONValue.self, from: b.handle(r).body).object?["id"])
        r.headers["MCP-Protocol-Version"] = "2025-11-25"
        r.body = Data("{\"jsonrpc\":\"1.0\"}".utf8)
        XCTAssertEqual(try errorCode(b.handle(r)), .number(-32600))
        r.body = Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8)
        XCTAssertEqual(try errorCode(b.handle(r)), .number(-32600))
        r.body = Data("[]".utf8)
        XCTAssertEqual(try errorCode(b.handle(r)), .number(-32600))
        r.body = Data(
            (String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)).utf8)
        XCTAssertEqual(b.handle(r).status, 400)
        r = try request("tools/list")
        r.headers["Accept"] = ";,;"
        XCTAssertEqual(b.handle(r).status, 406)
        r = try request("tools/list")
        r.body = Data(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"method\":\"tools/call\"}"
                .utf8)
        XCTAssertEqual(b.handle(r).status, 400)
        r.body = Data(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"list_recent\",\"arguments\":{\"limit\":1,\"limit\":2}}}"
                .utf8)
        XCTAssertEqual(b.handle(r).status, 400)
    }
    func testEncodedOutputBudgetAndPostCommitProjectionFailure() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID()
        _ = f.call("create_capture", f.create(id: id))
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: id, baseRevision: 1,
                mutation: .edit(
                    CaptureEdit(
                        generated: GeneratedContent(body: String(repeating: "\u{01}", count: 24576))
                    ))))
        let output = f.toolbox.call(
            name: "get_capture", arguments: ["id": .string(id.uuidString)], grant: f.grant)
        XCTAssertLessThan(try JSONEncoder().encode(output).count, 60_001)
        XCTAssertEqual(
            output.object?["structuredContent"]?.object?["output_truncated"], .bool(true))
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: id, baseRevision: 2,
                mutation: .edit(
                    CaptureEdit(
                        generated: GeneratedContent(body: String(repeating: "x", count: 262144))))))
        let edit: Object = [
            "operation_id": .string(UUID().uuidString), "sequence": .number(2),
            "id": .string(id.uuidString), "base_revision": .number(3), "rating": .number(4),
        ]
        let receipt = f.call("edit_capture", edit)
        XCTAssertEqual(receipt["isError"], .bool(false))
        XCTAssertEqual(receipt["structuredContent"]?.object?["outcome"], .string("accepted"))
        XCTAssertEqual(
            receipt["structuredContent"]?.object?["capture_content_unavailable"], .bool(true))
        XCTAssertEqual(f.call("edit_capture", edit)["isError"], .bool(false))
    }
    func testLibraryCeilingAndDirectGet() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let device = UUID()
        var first: UUID?
        for sequence in 1...1001 {
            let capture = SharedCapture(
                source: CaptureSource(kind: .text, selection: "fixture \(sequence)"))
            first = first ?? capture.id
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: device, sequence: Int64(sequence), captureID: capture.id,
                    baseRevision: 0, mutation: .create(capture)))
        }
        XCTAssertThrowsError(try f.store.snapshot())
        XCTAssertEqual(
            f.call("list_recent", [:])["structuredContent"]?.object?["error"],
            .string("bounded_library_capacity_exceeded"))
        XCTAssertEqual(
            f.call("get_capture", ["id": .string(first!.uuidString)])["isError"], .bool(false))
        let newStore = try AcceptedStore(
            databaseURL: f.directory.appendingPathComponent("authority.sqlite"), binding: f.binding)
        XCTAssertNotNil(try newStore.capture(id: first!))
    }
}
