import Foundation
import GRDB
import Testing

@testable import CapdSync

struct BulkAndBaselineTests {
    @Test func largeBaselinesAndFeedsStayInsideTheReplyBoundary() async throws {
        let f = try BoundedFixture()
        defer { f.clean() }
        let device = UUID()
        for index in 1...24 {
            var record = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "large-\(index)"))
            record.generated.body = String(repeating: "x", count: 800_000)
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: device, sequence: Int64(index),
                    captureID: record.id, baseRevision: 0, mutation: .create(record)))
        }
        #expect(
            try SyncDatabase.encode(f.server.baseline()).count > SyncHTTPHandler.maximumBodyBytes)
        let summary = try await f.wire.importBaseline(
            credential: { f.token }, requiringGeneratedProcessingContract: true, summaryOnly: true)
        #expect(summary.captures.isEmpty)
        #expect(summary.deviceSequences[device] == 24)
        let baseline = try await f.wire.importBaseline(credential: { f.token })
        #expect(baseline.captures.count == 24)
        #expect(baseline.captures.allSatisfy { $0.generated.body?.count == 800_000 })
        #expect(await f.wire.maximumReplyBytes <= SyncHTTPHandler.maximumBodyBytes)
        #expect(await f.wire.resourceLimits > 0)
        #expect(await f.wire.wholeBaselines == 0)
        let client = try SyncClient(
            databaseURL: f.root.appendingPathComponent("client.sqlite"),
            blobDirectory: f.root.appendingPathComponent("client-blobs"), deviceID: f.wire.deviceID,
            binding: f.wire.binding)
        while true {
            let cursor = try client.cursor()
            try await client.pull(from: f.wire, credential: { f.token })
            if try client.cursor() == cursor { break }
        }
        #expect(try client.captures().count == 24)
        #expect(try client.cursor() == baseline.cursor)
        try f.server.expireFeed(through: baseline.cursor)
        let synchronous = SyncHTTPTransport(
            binding: f.wire.binding, deviceID: f.wire.deviceID,
            credential: { f.token }, execute: { f.handler.handle($0) })
        let recovering = try SyncClient(
            databaseURL: f.root.appendingPathComponent("recovering.sqlite"),
            blobDirectory: f.root.appendingPathComponent("recovering-blobs"),
            deviceID: f.wire.deviceID, binding: f.wire.binding)
        try recovering.pull(from: synchronous)
        #expect(try recovering.captures() == baseline.captures)
        #expect(try recovering.cursor() == baseline.cursor)
    }

    @Test func baselinePagesRejectAChangedAuthorityCursor() async throws {
        let f = try BoundedFixture()
        defer { f.clean() }
        let device = UUID()
        for index in 1...101 {
            let record = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "pin-\(index)"))
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: device, sequence: Int64(index),
                    captureID: record.id, baseRevision: 0, mutation: .create(record)))
        }
        await f.wire.changeAfterFirstPage(on: f.server)
        await #expect(throws: SyncError.invalidCursor) {
            try await f.wire.importBaseline(credential: { f.token })
        }
        let synchronous = SyncHTTPTransport(
            binding: f.wire.binding, deviceID: f.wire.deviceID,
            credential: { f.token },
            execute: { request in
                let envelope = try SyncDatabase.decode(SyncHTTPEnvelope.self, request.body)
                let response = f.handler.handle(request)
                if case .baselinePage(nil, _, _) = envelope.action {
                    let record = SharedCapture(
                        source: CaptureSource(kind: .text, contentHash: "Synchronous new cursor"))
                    _ = try f.server.apply(
                        SyncOperation(
                            deviceID: UUID(), sequence: 1, captureID: record.id, baseRevision: 0,
                            mutation: .create(record)))
                }
                return response
            })
        #expect(throws: SyncError.invalidCursor) { try synchronous.baseline() }
    }

    @Test func batchedEditsProjectOnceAndKeepPredecessorsAndRollback() throws {
        let f = try BoundedFixture()
        defer { f.clean() }
        let writer = try DatabaseQueue(path: f.root.appendingPathComponent("batch.sqlite").path)
        try writer.write { try $0.execute(sql: "CREATE TABLE projections (id TEXT)") }
        let client = try SyncClient(
            writer: writer,
            blobs: BlobStore(directory: f.root.appendingPathComponent("batch-blobs")),
            project: { db, record in
                try db.execute(
                    sql: "INSERT INTO projections VALUES (?)", arguments: [record.id.uuidString])
            })
        let server = try SyncServer(
            databaseURL: f.root.appendingPathComponent("batch-server.sqlite"),
            blobDirectory: f.root.appendingPathComponent("batch-server-blobs"))
        let captures = (1...12).map {
            SharedCapture(source: CaptureSource(kind: .text, contentHash: "batch-\($0)"))
        }
        for capture in captures {
            try client.enqueue(captureID: capture.id, mutation: .create(capture))
        }
        try client.push(to: server)
        let pending = try client.enqueue(
            captureID: captures[0].id, mutation: .edit(CaptureEdit(note: NoteEdit("Earlier"))))
        try writer.write { try $0.execute(sql: "DELETE FROM projections") }
        let edits =
            captures.map { (captureID: $0.id, edit: CaptureEdit(rating: 4)) }
            + [(captureID: captures[0].id, edit: CaptureEdit(note: NoteEdit("Latest")))]
        let batch = try writer.write { try client.enqueue(in: $0, edits: edits) }
        #expect(batch[0].predecessorID == pending.id)
        #expect(batch.last?.predecessorID == batch[0].id)
        #expect(batch.map(\.sequence) == Array(14...26).map(Int64.init))
        #expect(
            try writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM projections") } == 12)
        #expect(try client.captures().first { $0.id == captures[0].id }?.note == "Latest")
        let before = try client.pendingOperations()
        #expect(throws: SyncError.invalidOperation) {
            try writer.write { db in
                try client.enqueue(
                    in: db,
                    edits: [
                        (captureID: captures[0].id, edit: CaptureEdit(rating: 2)),
                        (captureID: captures[1].id, edit: CaptureEdit(rating: 6)),
                    ])
            }
        }
        #expect(try client.pendingOperations() == before)
        try client.push(to: server)
        #expect(try server.baseline().captures.allSatisfy { $0.rating == 4 })
        #expect(try server.baseline().captures.first { $0.id == captures[0].id }?.note == "Latest")
    }
}

private struct BoundedFixture: Sendable {
    let root: URL
    let server: SyncServer
    let wire: BoundedWire
    let handler: SyncHTTPHandler
    let token = "synthetic-bounded-baseline"
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-bounded-\(UUID())")
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let deviceID = UUID()
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("blobs"), libraryID: binding.libraryID,
            serviceID: binding.serviceID)
        handler = SyncHTTPHandler(
            serviceID: binding.serviceID,
            authorizer: BoundedAuthorizer(
                token: token,
                principal: SyncPrincipal(
                    serviceID: binding.serviceID, libraryID: binding.libraryID,
                    deviceID: deviceID)),
            server: { [server] _ in server })
        wire = BoundedWire(binding: binding, deviceID: deviceID, handler: handler)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct BoundedAuthorizer: SyncAuthorizer {
    let token: String
    let principal: SyncPrincipal
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        bearerCredential == token ? principal : nil
    }
}

private actor BoundedWire: AsyncSyncTransport {
    nonisolated let binding: SyncLibraryBinding
    nonisolated let deviceID: UUID
    let handler: SyncHTTPHandler
    var maximumReplyBytes = 0
    var resourceLimits = 0
    var wholeBaselines = 0
    var changingServer: SyncServer?
    init(binding: SyncLibraryBinding, deviceID: UUID, handler: SyncHTTPHandler) {
        self.binding = binding
        self.deviceID = deviceID
        self.handler = handler
    }
    func changeAfterFirstPage(on server: SyncServer) { changingServer = server }
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        let envelope = try SyncDatabase.decode(SyncHTTPEnvelope.self, request.body)
        if case .baseline = envelope.action { wholeBaselines += 1 }
        let response = handler.handle(request)
        maximumReplyBytes = max(maximumReplyBytes, response.body.count)
        let reply = try SyncDatabase.decode(SyncHTTPReply.self, response.body)
        if case .failure(.resourceLimit) = reply.result { resourceLimits += 1 }
        if case .baselinePage(nil, let limit, _) = envelope.action, limit > 0,
            let server = changingServer, case .baseline = reply.result
        {
            changingServer = nil
            let record = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "New cursor"))
            _ = try server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: record.id,
                    baseRevision: 0, mutation: .create(record)))
        }
        return response
    }
}
