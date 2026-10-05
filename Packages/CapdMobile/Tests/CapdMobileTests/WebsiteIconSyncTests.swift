import CapdAnswers
import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdMobile

@Suite(.serialized)
struct WebsiteIconSyncTests {
    @Test(arguments: [false, true])
    func authenticatedCoordinatorDeliversIconsAndCaptureReceipts(asynchronous: Bool) async throws {
        let fixture = try MobileIconFixture()
        defer { fixture.clean() }
        try fixture.publishIcon()
        let store = try fixture.mobile()
        let local = try CaptureInput.make(text: "Phone orchid note", isLink: false)
        try store.save(local)
        let boundary = fixture.boundary()
        let coordinator = MobileSyncCoordinator(
            store: store, adapter: fixture.adapter(boundary, asynchronous: asynchronous))
        #expect(try await coordinator.sync() == .sent(1, rejected: 0))
        #expect(try store.pending().isEmpty)
        #expect(try fixture.server.baseline().captures.contains { $0.id == local.id })
        let record = try #require(
            try store.websiteIcon(for: fixture.origin.canonicalHTTPSOrigin + "/phone"))
        #expect(record.revision == 1)
        #expect(try store.websiteIconData(record) == mobileIconPNG)
        #expect(try store.websiteIconRevision() > 0)
        #expect(boundary.cursors == [0, 1])
        let unauthorized = fixture.boundary()
        let rejected = MobileSyncCoordinator(
            store: store,
            adapter: fixture.adapter(unauthorized, asynchronous: asynchronous, credential: "wrong"))
        await #expect(throws: SyncHTTPError.unauthorized) { try await rejected.sync() }
    }

    @Test(arguments: [false, true])
    func absentOptionalCapabilityKeepsCaptureSuccess(asynchronous: Bool) async throws {
        let fixture = try MobileIconFixture()
        defer { fixture.clean() }
        try fixture.publishIcon()
        let store = try fixture.mobile()
        let local = try CaptureInput.make(text: "Old server still accepts captures", isLink: false)
        try store.save(local)
        let boundary = fixture.boundary(omitCapability: true)
        let coordinator = MobileSyncCoordinator(
            store: store, adapter: fixture.adapter(boundary, asynchronous: asynchronous))
        #expect(
            try await coordinator.sync()
                == .sent(1, rejected: 0, websiteIconIssue: .unsupportedServer))
        #expect(try store.pending().isEmpty)
        #expect(try fixture.server.baseline().captures.contains { $0.id == local.id })
        #expect(try store.websiteIconRevision() == 0)
        #expect(try store.websiteIcon(for: fixture.origin.canonicalHTTPSOrigin) == nil)
        #expect(boundary.cursors.isEmpty)
        let controller = AutomaticSyncController(
            store: store, adapter: fixture.adapter(boundary, asynchronous: asynchronous))
        await controller.foreground()
        try await iconEventually { await controller.currentState().lastSuccessfulSync != nil }
        let state = await controller.currentState()
        await controller.suspend()
        #expect(state.websiteIconIssue == .unsupportedServer)
        #expect(state.pendingChanges == 0 && state.lastError == nil)
        #expect(state.websiteIconRevision == 0)
    }

    @Test func iconOnlyRefreshPublishesIndependentRevisionWithoutInvalidatingEvidence() async throws
    {
        let fixture = try MobileIconFixture()
        defer { fixture.clean() }
        let store = try fixture.mobile()
        let boundary = fixture.boundary()
        let coordinator = MobileSyncCoordinator(store: store, adapter: fixture.adapter(boundary))
        #expect(try await coordinator.sync() == .sent(0, rejected: 0))
        let captureRows = try store.search()
        let matches = try store.search("orchid")
        #expect(!matches.isEmpty)
        let reader = try DatabaseQueue(path: fixture.mobileURL.path)
        let fts = try iconFTSSnapshot(reader)
        let libraryRevision = try store.libraryRevision()
        let searchRevision = try store.systemSearchSnapshot().revision
        let retrieval = try MobileAnswerRetrieval(databaseURL: fixture.mobileURL)
        let evidenceRevision = try await retrieval.evidenceRevision()
        let evidence = try await retrieval.search("orchid", limit: 12)
        #expect(!evidence.isEmpty)
        #expect(try store.websiteIconRevision() == 0)
        try fixture.publishIcon()
        try await store.pullWebsiteIcons(
            from: fixture.asyncTransport(boundary), credential: { fixture.phone.uuidString })
        let controller = AutomaticSyncController(store: store, adapter: fixture.adapter(boundary))
        let state = await controller.currentState()
        #expect(try state.websiteIconRevision == store.websiteIconRevision())
        #expect(state.websiteIconRevision > 0 && state.websiteIconIssue == nil)
        #expect(state.libraryRevision == libraryRevision)
        #expect(try store.libraryRevision() == libraryRevision)
        #expect(try store.search() == captureRows)
        #expect(try store.search("orchid") == matches)
        #expect(try iconFTSSnapshot(reader) == fts)
        #expect(try store.systemSearchSnapshot().revision == searchRevision)
        #expect(try await retrieval.evidenceRevision() == evidenceRevision)
        #expect(try await retrieval.search("orchid", limit: 12) == evidence)
        await controller.foreground()
        try await iconEventually { await controller.currentState().lastSuccessfulSync != nil }
        let completed = await controller.currentState()
        await controller.suspend()
        #expect(completed.websiteIconRevision == state.websiteIconRevision)
        #expect(completed.libraryRevision == libraryRevision && completed.websiteIconIssue == nil)
    }

    @Test func boundCaptureOnlyTransportReportsUnsupportedIconsAfterAcceptingCapture() async throws
    {
        let fixture = try MobileIconFixture()
        defer { fixture.clean() }
        let store = try fixture.mobile()
        let capture = try CaptureInput.make(text: "Capture-only bound transport", isLink: false)
        try store.save(capture)
        let boundary = fixture.boundary()
        let adapter = MobileIconCaptureOnlyAdapter(
            remote: MobileIconCaptureOnlyTransport(
                remote: fixture.transport(boundary)))
        let coordinator = MobileSyncCoordinator(store: store, adapter: adapter)
        #expect(
            try await coordinator.sync()
                == .sent(1, rejected: 0, websiteIconIssue: .unsupportedServer))
        #expect(try store.pending().isEmpty)
        #expect(try fixture.server.baseline().captures.contains { $0.id == capture.id })
        #expect(try store.websiteIconRevision() == 0 && boundary.cursors.isEmpty)
    }

    @Test(arguments: [false, true])
    func boundedPullUsesDurableBeforeAndAfterCursor(asynchronous: Bool) async throws {
        let fixture = try MobileIconFixture()
        defer { fixture.clean() }
        for revision in 1...10 { try fixture.publishIcon(fetchedAt: TimeInterval(revision)) }
        let store = try fixture.mobile()
        let boundary = fixture.boundary(oneRecordPages: true)
        if asynchronous {
            try await store.pullWebsiteIcons(
                from: fixture.asyncTransport(boundary), credential: { fixture.phone.uuidString })
        } else {
            try store.pullWebsiteIcons(from: fixture.transport(boundary))
        }
        #expect(boundary.cursors == Array(0...7).map(Int64.init))
        #expect(try store.websiteIcon(for: fixture.origin.canonicalHTTPSOrigin)?.revision == 8)
        let reopened = try fixture.mobile()
        if asynchronous {
            try await reopened.pullWebsiteIcons(
                from: fixture.asyncTransport(boundary), credential: { fixture.phone.uuidString })
        } else {
            try reopened.pullWebsiteIcons(from: fixture.transport(boundary))
        }
        #expect(boundary.cursors == Array(0...10).map(Int64.init))
        let record = try #require(
            try reopened.websiteIcon(for: fixture.origin.canonicalHTTPSOrigin))
        #expect(record.revision == 10)
        #expect(try reopened.websiteIconData(record) == mobileIconPNG)
        let count = boundary.cursors.count
        if asynchronous {
            try await reopened.pullWebsiteIcons(
                from: fixture.asyncTransport(boundary), credential: { fixture.phone.uuidString })
        } else {
            try reopened.pullWebsiteIcons(from: fixture.transport(boundary))
        }
        #expect(boundary.cursors.count == count + 1)
        #expect(boundary.cursors.last == 10)
    }

    @Test func cancelledIconPullDoesNotPublishACompletedRefresh() async throws {
        let fixture = try MobileIconFixture()
        defer { fixture.clean() }
        try fixture.publishIcon()
        let store = try fixture.mobile()
        let boundary = fixture.boundary(cancelGate: true)
        let coordinator = MobileSyncCoordinator(store: store, adapter: fixture.adapter(boundary))
        let flight = Task { try await coordinator.sync() }
        try await iconEventually { boundary.waiting }
        await coordinator.cancelAndDrain()
        await #expect(throws: CancellationError.self) { try await flight.value }
        #expect(try store.websiteIconRevision() == 0)
        #expect(try store.websiteIcon(for: fixture.origin.canonicalHTTPSOrigin) == nil)
        let automaticBoundary = fixture.boundary(cancelGate: true)
        let controller = AutomaticSyncController(
            store: store, adapter: fixture.adapter(automaticBoundary))
        await controller.foreground()
        try await iconEventually { automaticBoundary.waiting }
        await controller.suspend()
        let state = await controller.currentState()
        #expect(state.phase == .paused)
        #expect(state.lastSuccessfulSync == nil && state.websiteIconIssue == nil)
        #expect(state.websiteIconRevision == 0)
    }
}

private struct MobileIconFixture: Sendable {
    let root: URL
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let publisherDevice = UUID()
    let phone = UUID()
    let origin = WebsiteIconOrigin(url: "https://www.capd.dev")!
    let server: SyncServer
    let publisher: SyncClient
    var mobileURL: URL { root.appendingPathComponent("phone.sqlite") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mobile-icon-\(UUID())")
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-assets"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        publisher = try SyncClient(
            databaseURL: root.appendingPathComponent("publisher.sqlite"),
            blobDirectory: root.appendingPathComponent("publisher-assets"),
            deviceID: publisherDevice, binding: binding)
        let capture = SharedCapture(
            source: CaptureSource(
                kind: .link, contentHash: "https://www.capd.dev/orchid",
                url: "https://www.capd.dev/orchid", title: "Orchid source",
                selection: "Saved orchid evidence is independent of website icons."))
        try publisher.enqueue(captureID: capture.id, mutation: .create(capture))
        let principal = SyncPrincipal(
            serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: publisherDevice)
        let authority = server
        let handler = SyncHTTPHandler(
            serviceID: binding.serviceID, authorizer: MobileIconAuthorizer(principal: principal),
            server: { _ in authority })
        let transport = SyncHTTPTransport(
            binding: binding, deviceID: publisherDevice,
            credential: { principal.deviceID.uuidString }, execute: handler.handle)
        try publisher.push(to: transport)
    }
    func mobile() throws -> MobileStore {
        try MobileStore(url: mobileURL, deviceID: phone, binding: binding)
    }
    func publishIcon(fetchedAt: TimeInterval = 1) throws {
        let blob = try publisher.blobs.put(mobileIconPNG)
        try publisher.enqueueWebsiteIcon(
            origin: origin,
            mutation: .upsert(
                WebsiteIconContent(blob: blob, fetchedAt: Date(timeIntervalSince1970: fetchedAt))))
        try publisher.pushWebsiteIcons(
            to: SyncHTTPTransport(
                binding: binding, deviceID: publisherDevice,
                credential: { publisherDevice.uuidString },
                execute: boundary(device: publisherDevice).execute))
    }
    func boundary(
        device: UUID? = nil, omitCapability: Bool = false, oneRecordPages: Bool = false,
        cancelGate: Bool = false
    ) -> MobileIconBoundary {
        let principal = SyncPrincipal(
            serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: device ?? phone)
        return MobileIconBoundary(
            handler: SyncHTTPHandler(
                serviceID: binding.serviceID,
                authorizer: MobileIconAuthorizer(principal: principal), server: { _ in server }),
            omitCapability: omitCapability, oneRecordPages: oneRecordPages, cancelGate: cancelGate)
    }
    func transport(_ boundary: MobileIconBoundary, credential: String? = nil) -> SyncHTTPTransport {
        SyncHTTPTransport(
            binding: binding, deviceID: phone, credential: { credential ?? phone.uuidString },
            execute: boundary.execute)
    }
    func asyncTransport(_ boundary: MobileIconBoundary) -> MobileIconAsyncTransport {
        .init(binding: binding, deviceID: phone, boundary: boundary)
    }
    func adapter(
        _ boundary: MobileIconBoundary, asynchronous: Bool = true, credential: String? = nil
    ) -> MobileIconAdapter {
        MobileIconAdapter(
            synchronous: asynchronous ? nil : transport(boundary, credential: credential),
            asynchronous: asynchronous
                ? .init(
                    transport: asyncTransport(boundary),
                    credential: { credential ?? phone.uuidString }) : nil)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
private struct MobileIconAuthorizer: SyncAuthorizer {
    let principal: SyncPrincipal
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        bearerCredential == principal.deviceID.uuidString ? principal : nil
    }
}
private struct MobileIconAdapter: MobileSyncAdapter {
    let synchronous: SyncHTTPTransport?
    let asynchronous: MobileAsyncSyncConnection?
    func availability() async -> SyncAvailability { .ready }
    func transport() async -> (any SyncTransport)? { synchronous }
    func asyncConnection() async -> MobileAsyncSyncConnection? { asynchronous }
}
private struct MobileIconCaptureOnlyAdapter: MobileSyncAdapter {
    let remote: MobileIconCaptureOnlyTransport
    func availability() async -> SyncAvailability { .ready }
    func transport() async -> (any SyncTransport)? { remote }
}
private struct MobileIconCaptureOnlyTransport: BoundSyncTransport {
    let remote: SyncHTTPTransport
    var binding: SyncLibraryBinding { remote.binding }
    var deviceID: UUID { remote.deviceID }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt { try remote.apply(operation) }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try remote.changes(after: cursor, limit: limit)
    }
    func baseline() throws -> Baseline { try remote.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try remote.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try remote.download(blob) }
}
private struct MobileIconAsyncTransport: AsyncSyncTransport {
    let binding: SyncLibraryBinding
    let deviceID: UUID
    let boundary: MobileIconBoundary
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        if boundary.cancelGate,
            case .websiteIconChanges = try JSONDecoder().decode(
                SyncHTTPEnvelope.self, from: request.body
            ).action
        {
            boundary.markWaiting()
            try await Task.sleep(for: .seconds(5))
            try Task.checkCancellation()
        }
        return try boundary.execute(request)
    }
}
private final class MobileIconBoundary: @unchecked Sendable {
    let handler: SyncHTTPHandler
    let omitCapability: Bool
    let oneRecordPages: Bool
    let cancelGate: Bool
    private let lock = NSLock()
    private var requestedCursors: [Int64] = []
    private var isWaiting = false
    var cursors: [Int64] { lock.withLock { requestedCursors } }
    var waiting: Bool { lock.withLock { isWaiting } }
    init(handler: SyncHTTPHandler, omitCapability: Bool, oneRecordPages: Bool, cancelGate: Bool) {
        self.handler = handler
        self.omitCapability = omitCapability
        self.oneRecordPages = oneRecordPages
        self.cancelGate = cancelGate
    }
    func markWaiting() { lock.withLock { isWaiting = true } }
    func execute(_ request: SyncHTTPRequest) throws -> SyncHTTPResponse {
        var effective = request
        let envelope = try JSONDecoder().decode(SyncHTTPEnvelope.self, from: request.body)
        if case .websiteIconChanges(let cursor, _) = envelope.action {
            lock.withLock { requestedCursors.append(cursor) }
            if oneRecordPages {
                effective = SyncHTTPRequest(
                    method: request.method, path: request.path, headers: request.headers,
                    body: try JSONEncoder().encode(
                        SyncHTTPEnvelope(
                            version: envelope.version,
                            expectedServiceID: envelope.expectedServiceID,
                            expectedLibraryID: envelope.expectedLibraryID,
                            expectedDeviceID: envelope.expectedDeviceID,
                            action: .websiteIconChanges(cursor: cursor, limit: 1))))
            }
        }
        let response = handler.handle(effective)
        guard omitCapability else { return response }
        let reply = try JSONDecoder().decode(SyncHTTPReply.self, from: response.body)
        return SyncHTTPResponse(
            status: response.status, headers: response.headers,
            body: try JSONEncoder().encode(
                SyncHTTPReply(
                    version: reply.version, principal: reply.principal, result: reply.result,
                    metadataContractVersion: reply.metadataContractVersion,
                    generatedProcessingContractVersion: reply.generatedProcessingContractVersion,
                    extractionQualityContractVersion: reply.extractionQualityContractVersion)))
    }
}
private func iconEventually(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Website icon sync condition did not become true")
    throw SyncError.transportDisconnected
}
private let mobileIconPNG = Data(
    base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAqElEQVR4nOXOIQEAAAwEoetf+hcDMYGnas/xgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9QB1h88OKlPjZIAAAAAElFTkSuQmCC"
)!

private struct MobileIconFTSState: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let id: Int64
        let block: Data
    }
    let rows: [[String?]]
    let segments: [Segment]
}
private func iconFTSSnapshot(_ reader: DatabaseQueue) throws -> MobileIconFTSState {
    try reader.read { db in
        let rows = try Row.fetchAll(
            db, sql: "SELECT rowid, * FROM mobile_captures_fts ORDER BY rowid"
        ).map { row in
            let rowID: Int64 = row["rowid"]
            return [String(rowID)]
                + ["title", "selection", "note", "manualTags", "generatedTags", "body", "ocrText"]
                .map { row[$0] as String? }
        }
        let segments = try Row.fetchAll(
            db, sql: "SELECT id, block FROM mobile_captures_fts_data ORDER BY id"
        ).map { row in
            MobileIconFTSState.Segment(id: row["id"], block: row["block"])
        }
        return MobileIconFTSState(rows: rows, segments: segments)
    }
}
