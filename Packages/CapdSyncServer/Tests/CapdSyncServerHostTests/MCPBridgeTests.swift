import CapdMCP
import CapdSync
import CryptoKit
import Darwin
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import SQLite3
import Testing

@testable import CapdSyncServerHost

@Suite("Separate assistant bridge") struct MCPBridgeTests {
    @Test func disabledUnauthorizedAndMissingLibraryDoNotOpenCaptureStorage() async throws {
        let f = try BridgeFixture()
        defer { f.clean() }
        var authority: Authority? = try Authority(
            configurationURL: f.syncConfig, dataDirectory: f.data)
        #expect(await authority!.handleMCP(try f.rpc()).status == 404)
        authority = nil
        let enabled = try f.authority()
        #expect(await enabled.handleMCP(try f.rpc(bearer: f.macBearer)).status == 401)
        #expect(
            await enabled.handleMCP(try f.rpc(bearer: "sk-unrelated-runtime-key")).status == 401)
        #expect(!FileManager.default.fileExists(atPath: f.libraryRoot.path))
        #expect(await enabled.handleMCP(try f.rpc()).status == 503)
        #expect(!FileManager.default.fileExists(atPath: f.libraryRoot.path))
        #expect(await enabled.handle(try f.sync(.baseline, bearer: f.bridgeBearer)).status == 401)
        #expect(!FileManager.default.fileExists(atPath: f.libraryRoot.path))
        // An unreadable/non-database capture file is never touched for a refused credential.
        try FileManager.default.createDirectory(
            at: f.libraryRoot, withIntermediateDirectories: true)
        let badDB = f.libraryRoot.appendingPathComponent("authority.sqlite")
        try Data("not a database".utf8).write(to: badDB)
        #expect(await enabled.handleMCP(try f.rpc(bearer: f.macBearer)).status == 401)
        #expect(try Data(contentsOf: badDB) == Data("not a database".utf8))
    }

    @Test func emptyAndUninitializedDatabaseNeverCreatesAuthorityTables() async throws {
        let f = try BridgeFixture()
        defer { f.clean() }
        let authority = try f.authority()
        try FileManager.default.createDirectory(
            at: f.libraryRoot, withIntermediateDirectories: true)
        let database = f.libraryRoot.appendingPathComponent("authority.sqlite")
        for placeholder in [Data(), Data("not a database".utf8)] {
            try placeholder.write(to: database)
            #expect(await authority.handleMCP(try f.create()).status == 503)
            #expect(try Data(contentsOf: database) == placeholder)
            #expect(
                !FileManager.default.fileExists(
                    atPath: f.libraryRoot.appendingPathComponent("blobs").path))
        }
    }

    @Test(
        arguments: [
            "authority.sqlite-wal", "authority.sqlite-shm", "authority.sqlite-journal",
        ])
    func unsafeSQLiteSidecarsAreRejectedBeforeMCPStoreOpen(name: String) async throws {
        let f = try BridgeFixture()
        defer { f.clean() }
        var authority: Authority? = try f.authority()
        #expect(await authority!.handle(try f.sync(.baseline)).status == 200)
        authority = nil

        let sidecar = f.libraryRoot.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
        let target = f.root.appendingPathComponent("outside-sqlite-sidecar")
        let sentinel = Data("outside synthetic sidecar sentinel".utf8)
        try sentinel.write(to: target)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)

        let reopened = try f.authority()
        #expect(await reopened.handleMCP(try f.rpc()).status == 503)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: sidecar.path) == target.path)
        #expect(try Data(contentsOf: target) == sentinel)
    }

    @Test func partialAuthoritySchemaIsRefusedWithoutRepair() async throws {
        let f = try BridgeFixture()
        defer { f.clean() }
        var authority: Authority? = try f.authority()
        #expect(await authority!.handle(try f.sync(.baseline)).status == 200)
        authority = nil
        let file = f.libraryRoot.appendingPathComponent("authority.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(file.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "DROP TABLE sync_receipts", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_close(database) == SQLITE_OK)
        let before = try Data(contentsOf: file)
        authority = try f.authority()
        #expect(await authority!.handleMCP(try f.create()).status == 503)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test(arguments: ["blobs", "marker", "wrong-owner", "marker-symlink"])
    func incompleteBlobStorageIsRefusedWithoutRepair(missing: String) async throws {
        let f = try BridgeFixture()
        defer { f.clean() }
        var authority: Authority? = try f.authority()
        #expect(await authority!.handle(try f.sync(.baseline)).status == 200)
        authority = nil
        let blobs = f.libraryRoot.appendingPathComponent("blobs")
        let marker = blobs.appendingPathComponent("library-owner")
        if missing == "blobs" {
            try FileManager.default.removeItem(at: blobs)
        } else {
            try FileManager.default.removeItem(at: marker)
            if missing == "wrong-owner" {
                try JSONEncoder().encode(
                    SyncLibraryBinding(libraryID: UUID(), serviceID: f.service)
                ).write(to: marker)
            } else if missing == "marker-symlink" {
                let target = f.root.appendingPathComponent("external-owner")
                try JSONEncoder().encode(
                    SyncLibraryBinding(libraryID: f.library, serviceID: f.service)
                ).write(to: target)
                try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
            }
        }
        let database = f.libraryRoot.appendingPathComponent("authority.sqlite")
        let before = try Data(contentsOf: database)
        authority = try f.authority()
        #expect(await authority!.handleMCP(try f.rpc()).status == 503)
        #expect(await authority!.handleMCP(try f.create()).status == 503)
        #expect(try Data(contentsOf: database) == before)
        if missing == "blobs" { #expect(!FileManager.default.fileExists(atPath: blobs.path)) }
        if missing == "marker" { #expect(!FileManager.default.fileExists(atPath: marker.path)) }
        if missing == "marker-symlink" {
            #expect(
                try FileManager.default.destinationOfSymbolicLink(atPath: marker.path)
                    == f.root.appendingPathComponent("external-owner").path)
        }
    }

    @Test func stalledBodiesExpireAndReleaseAllAdmissionSlots() async throws {
        let f = try BridgeFixture()
        defer { f.clean() }
        let authority = try f.authority()
        let admission = Admission()
        let streams = (0..<8).map { _ in RequestBody.makeStream() }
        await withTaskGroup(of: Void.self) { group in
            for (body, _) in streams {
                group.addTask {
                    let response = await HostHTTP.handleMCPBody(
                        body, headers: [:], authority: authority, admission: admission,
                        deadline: .now() + .milliseconds(20))
                    #expect(response.status.code == 504)
                }
            }
        }
        for _ in 0..<8 { #expect(await admission.acquire()) }
        #expect(!(await admission.acquire()))
        for _ in 0..<8 { await admission.release() }
        #expect(await authority.handle(try f.sync(.baseline)).status == 200)
        #expect(try f.baseline(await authority.handle(try f.sync(.baseline))).captures.isEmpty)
        for (_, source) in streams { source.finish() }
        let body = RequestBody(buffer: ByteBuffer(string: "synthetic"))
        #expect(
            try await HostHTTP.collectMCPBody(body, deadline: .now() + .seconds(1))
                == ByteBuffer(string: "synthetic"))
        do {
            _ = try await HostHTTP.collectMCPBody(
                RequestBody(buffer: ByteBuffer(repeating: 0, count: 65_537)),
                deadline: .now() + .seconds(1))
            Issue.record("Oversized body unexpectedly accepted")
        } catch {
            #expect(error is NIOTooManyBytesError)
        }
    }

    @Test func sameCachedAuthorityAndOrdinarySyncRetryDeletion() async throws {
        let f = try BridgeFixture()
        defer { f.clean() }
        let authority = try f.authority()
        #expect(await authority.handle(try f.sync(.baseline)).status == 200)
        let original = try authority.queue.sync {
            try authority.server(for: f.library, requireExisting: true)
        }
        let id = UUID()
        let request = try f.create(id: id)
        let first = await authority.handleMCP(request)
        #expect(first.status == 200 && f.success(first))
        let replay = await authority.handleMCP(request)
        #expect(f.success(replay))
        let cached = try authority.queue.sync {
            try authority.server(for: f.library, requireExisting: true)
        }
        #expect(original === cached)
        let baseline = try f.baseline(await authority.handle(try f.sync(.baseline)))
        #expect(baseline.captures.count == 1 && baseline.deviceSequences[f.writer] == 1)
        let deletion = SyncOperation(
            deviceID: f.macDevice, sequence: 1, captureID: id, baseRevision: 1, mutation: .delete)
        let deleteRequest = try f.sync(.apply(deletion))
        let removed = await authority.handle(deleteRequest)
        #expect(removed.status == 200)
        #expect(await authority.handle(deleteRequest).body == removed.body)
        let historical = await authority.handleMCP(request)
        #expect(
            !String(decoding: historical.body, as: UTF8.self).contains("sensitive-deleted-fixture"))
        #expect(
            !String(
                decoding: await authority.handleMCP(
                    try f.rpc(
                        method: "tools/call",
                        params: ["name": "list_recent", "arguments": ["limit": 1]])
                ).body, as: UTF8.self
            ).contains("sensitive-deleted-fixture"))
    }

    @Test func queuedRevocationIsReadAfterAdmissionAndExpiryCannotWrite() async throws {
        let f = try BridgeFixture()
        defer { f.clean() }
        let authority = try f.authority()
        #expect(await authority.handle(try f.sync(.baseline)).status == 200)
        let hold = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        authority.queue.async {
            entered.signal()
            hold.wait()
        }
        #expect(await waitForSignal(entered) == .success)
        let queuedRequest = try f.create()
        let queued = Task { await authority.handleMCP(queuedRequest) }
        for _ in 0..<200 where authority.mcpQueueLimit.count == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(authority.mcpQueueLimit.count == 1)
        try f.writePolicy(revoked: true)
        hold.signal()
        #expect(await queued.value.status == 401)
        #expect(try f.baseline(await authority.handle(try f.sync(.baseline))).captures.isEmpty)
        try f.writePolicy()
        let holdAgain = DispatchSemaphore(value: 0)
        let enteredAgain = DispatchSemaphore(value: 0)
        authority.queue.async {
            enteredAgain.signal()
            holdAgain.wait()
        }
        #expect(await waitForSignal(enteredAgain) == .success)
        let expired = await authority.handleMCP(
            try f.create(), deadline: .now() + .milliseconds(10))
        #expect(expired.status == 504)
        holdAgain.signal()
        let baseline = try f.baseline(await authority.handle(try f.sync(.baseline)))
        #expect(baseline.captures.isEmpty && baseline.deviceSequences[f.writer] == nil)
    }

    @Test func oneSharedWriterDoesNotSilentlyRenumberContention() async throws {
        let f = try BridgeFixture()
        defer { f.clean() }
        let authority = try f.authority()
        _ = await authority.handle(try f.sync(.baseline))
        let a = try f.create()
        let b = try f.create()
        async let left = authority.handleMCP(a)
        async let right = authority.handleMCP(b)
        let results = await [left, right]
        #expect(results.filter { f.success($0) }.count == 1)
        let baseline = try f.baseline(await authority.handle(try f.sync(.baseline)))
        #expect(baseline.captures.count == 1 && baseline.deviceSequences[f.writer] == 1)
    }

    @Test func strictPolicyAndNoOAuthDiscoveryOrScopeUpgrade() async throws {
        let f = try BridgeFixture()
        defer { f.clean() }
        let authority = try f.authority()
        _ = await authority.handle(try f.sync(.baseline))
        try f.writePolicy(readOnly: true)
        let definitions = await authority.handleMCP(try f.rpc())
        let object = try JSONSerialization.jsonObject(with: definitions.body) as! [String: Any]
        let tools = (object["result"] as! [String: Any])["tools"] as! [[String: Any]]
        #expect(tools.count == 3)
        #expect(
            tools.allSatisfy {
                ($0["securitySchemes"] as? [[String: String]]) == [["type": "noauth"]]
            })
        let denied = await authority.handleMCP(try f.create())
        #expect(denied.status == 403 && denied.headers["WWW-Authenticate"] == nil)
        #expect(!String(decoding: denied.body, as: UTF8.self).contains("mcp/www_authenticate"))
        #expect(
            await authority.handleMCP(
                MCPHTTPRequest(method: "GET", path: "/.well-known/oauth-protected-resource/mcp")
            ).status == 404)
        var policy = f.policy()
        policy["credentialSHA256"] = f.digest(f.macBearer)
        try f.write(policy)
        #expect(await authority.handleMCP(try f.rpc(bearer: f.macBearer)).status == 503)
        try f.writePolicy()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: f.bridgeConfig.path)
        #expect(throws: (any Error).self) { try MCPBridgeConfiguration.read(f.bridgeConfig) }
        try f.writePolicy()
        let data = try Data(contentsOf: f.bridgeConfig)
        var duplicate = String(decoding: data, as: UTF8.self)
        duplicate.insert(
            contentsOf: "\"version\":1,", at: duplicate.index(after: duplicate.startIndex))
        try Data(duplicate.utf8).write(to: f.bridgeConfig)
        #expect(throws: (any Error).self) { try MCPBridgeConfiguration.read(f.bridgeConfig) }
    }

    @Test func sensitiveHeadersAndQueueCapacityRemainBounded() {
        var fields: HTTPFields = [
            .authorization: "Bearer fixture", .contentType: "application/json",
            .accept: "application/json, text/event-stream",
        ]
        fields.append(HTTPField(name: HTTPField.Name("MCP-Method")!, value: "tools/list"))
        #expect(HostHTTP.mcpHeaders(fields)?["mcp-method"] == "tools/list")
        fields.append(HTTPField(name: .accept, value: "duplicate"))
        #expect(HostHTTP.mcpHeaders(fields) == nil)
        #expect(HostHTTP.mcpHeaders([.accept: String(repeating: "x", count: 16_385)]) == nil)
        let limit = MCPQueueLimit()
        for _ in 0..<8 { #expect(limit.acquire()) }
        #expect(!limit.acquire())
        limit.release()
        #expect(limit.acquire())
    }

    @Test func runningTimeoutStaysUncertainAfterLateCompletion() async {
        let work = MCPWork(deadline: .now() + .seconds(5))
        #expect(work.begin())
        let reply = await withCheckedContinuation { continuation in
            work.install(continuation)
            work.expire()
            work.complete(MCPHTTPResponse(status: 200))
        }
        #expect(reply.status == 504)
        #expect(String(decoding: reply.body, as: UTF8.self).contains("Outcome may be unknown"))
        #expect(!work.mayExecute())
    }
}

private struct BridgeFixture: Sendable {
    let root: URL, syncConfig: URL, bridgeConfig: URL, data: URL
    let service = UUID(), library = UUID(), macDevice = UUID(), writer = UUID()
    let macBearer = String(repeating: "a", count: 64),
        bridgeBearer = String(repeating: "b", count: 64)
    var libraryRoot: URL { data.appendingPathComponent(library.uuidString.lowercased()) }
    init() throws {
        root = try canonicalTemporaryDirectory()
            .appendingPathComponent("capd-mcp-host-\(UUID())")
        syncConfig = root.appendingPathComponent("sync.json")
        bridgeConfig = root.appendingPathComponent("bridge.json")
        data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: [
            "serviceID": service.uuidString,
            "enrollments": [
                [
                    "libraryID": library.uuidString, "deviceID": macDevice.uuidString,
                    "credentialSHA256": digest(macBearer), "revoked": false,
                ]
            ],
        ]).write(to: syncConfig)
        try writePolicy()
    }
    func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func policy(revoked: Bool = false, readOnly: Bool = false) -> [String: Any] {
        var object: [String: Any] = [
            "version": 1, "serviceID": service.uuidString, "libraryID": library.uuidString,
            "resource": "https://synthetic.example.invalid/mcp", "principalID": "shared-fixture",
            "credentialSHA256": digest(bridgeBearer),
            "scopes": readOnly ? ["capd:read"] : ["capd:read", "capd:write"], "revoked": revoked,
        ]
        if !readOnly { object["writerDeviceID"] = writer.uuidString }
        return object
    }
    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: bridgeConfig, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: bridgeConfig.path)
    }
    func writePolicy(revoked: Bool = false, readOnly: Bool = false) throws {
        try write(policy(revoked: revoked, readOnly: readOnly))
    }
    func authority() throws -> Authority {
        try Authority(
            configurationURL: syncConfig, dataDirectory: data, mcpConfigurationURL: bridgeConfig)
    }
    func sync(_ action: SyncHTTPAction, bearer: String? = nil) throws -> SyncHTTPRequest {
        SyncHTTPRequest(
            method: "POST", path: "/v1/sync",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(bearer ?? macBearer)",
            ],
            body: try JSONEncoder().encode(
                SyncHTTPEnvelope(
                    expectedServiceID: service, expectedLibraryID: library,
                    expectedDeviceID: macDevice, action: action)))
    }
    func rpc(method: String = "tools/list", params: [String: Any] = [:], bearer: String? = nil)
        throws -> MCPHTTPRequest
    {
        MCPHTTPRequest(
            method: "POST", path: "/mcp",
            headers: [
                "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                "Authorization": "Bearer \(bearer ?? bridgeBearer)",
            ],
            body: try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
            ]))
    }
    func create(id: UUID = UUID()) throws -> MCPHTTPRequest {
        try rpc(
            method: "tools/call",
            params: [
                "name": "create_capture",
                "arguments": [
                    "operation_id": UUID().uuidString, "sequence": 1, "id": id.uuidString,
                    "kind": "text", "created_at": "2026-10-04T10:00:00Z",
                    "text": "sensitive-deleted-fixture",
                ],
            ])
    }
    func success(_ reply: MCPHTTPResponse) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
            let result = object["result"] as? [String: Any]
        else { return false }
        return (result["isError"] as? Bool) == false
    }
    func baseline(_ reply: SyncHTTPResponse) throws -> Baseline {
        let envelope = try JSONDecoder().decode(SyncHTTPReply.self, from: reply.body)
        guard case .baseline(let value) = envelope.result else {
            throw HostError.invalidConfiguration
        }
        return value
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private func waitForSignal(_ semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + .seconds(1)))
        }
    }
}

private func canonicalTemporaryDirectory() throws -> URL {
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        throw MCPFailure.unavailable
    }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}
