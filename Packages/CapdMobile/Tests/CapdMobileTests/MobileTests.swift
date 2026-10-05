import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdMobile

private struct Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-mobile-sync-\(UUID())")
    var url: URL { directory.appendingPathComponent("captures.sqlite") }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    func server() throws -> SyncServer {
        try SyncServer(
            databaseURL: directory.appendingPathComponent("authority.sqlite"),
            blobDirectory: directory.appendingPathComponent("authority-assets"))
    }
    func mac() throws -> SyncClient {
        try SyncClient(
            databaseURL: directory.appendingPathComponent("mac.sqlite"),
            blobDirectory: directory.appendingPathComponent("mac-assets"))
    }
}

private struct TestAdapter: MobileSyncAdapter {
    let state: SyncAvailability
    let connection: (any SyncTransport)?
    init(_ state: SyncAvailability, transport: (any SyncTransport)? = nil) {
        self.state = state
        connection = transport
    }
    func availability() async -> SyncAvailability { state }
    func transport() async -> (any SyncTransport)? { connection }
}

private final class DroppedAcknowledgement: SyncTransport, @unchecked Sendable {
    let server: SyncServer
    private let lock = NSLock()
    private var drop = true
    init(_ server: SyncServer) { self.server = server }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        let receipt = try server.apply(operation)
        let shouldDrop = lock.withLock {
            let result = drop
            drop = false
            return result
        }
        if shouldDrop { throw SyncError.acknowledgementLost }
        return receipt
    }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try server.changes(after: cursor, limit: limit)
    }
    func baseline() throws -> Baseline { try server.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try server.download(blob) }
}

@Test func oneOutboxAndDeviceSurviveReopenAndShareWriter() throws {
    let f = Fixture()
    defer { f.clean() }
    let app = try MobileStore(url: f.url)
    let share = try MobileStore(url: f.url)
    let capture = try CaptureInput.make(
        text: "https://example.invalid/source?q=one&x=two",
        title: "Saved page", note: "Keep for later", isLink: true)
    let operation = try share.save(capture)
    #expect(app.deviceID == share.deviceID)
    #expect(try app.search("keep for later").map(\.id) == [capture.id])
    let reopened = try MobileStore(url: f.url)
    #expect(reopened.deviceID == app.deviceID)
    let saved = try #require(reopened.search("example.invalid").first)
    #expect(saved.localID != nil)
    #expect(saved.id == capture.id)
    #expect(saved.url == capture.url)
    let queued = try #require(reopened.pending().first)
    #expect(queued.id == operation)
    #expect(queued.deviceID == app.deviceID)
    #expect(queued.sequence == 1)
    #expect(queued.baseRevision == 0)
    guard case .create(let payload) = queued.mutation else {
        Issue.record("Expected create operation")
        return
    }
    #expect(payload.id == capture.id)
    #expect(payload.note == capture.note)
    let database = try DatabaseQueue(path: f.url.path)
    try database.read { db in
        let hasLegacy = try db.tableExists("pendingCaptures")
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox")
        #expect(!hasLegacy)
        #expect(count == 1)
    }
}

@Test func searchUsesSourceRowsFTSAndLiteralURLFallback() throws {
    let f = Fixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.url)
    let capture = try CaptureInput.make(
        text: "An offline source with 100% coverage and _literal_ markers.",
        title: "Field note", isLink: false)
    try store.save(capture)
    #expect(try store.search("OFFLINE SOURCE").map(\.id) == [capture.id])
    #expect(try store.search("100%").map(\.selection) == [capture.selection])
    #expect(try store.search("_literal_").map(\.id) == [capture.id])
    #expect(throws: SyncError.invalidOperation) { try store.save(capture) }
    try store.update(id: capture.id, note: "Kestrel observation", tags: ["manual"])
    #expect(try store.search("kestrel").map(\.id) == [capture.id])
    #expect(try store.search("manual").map(\.id) == [capture.id])
    try store.delete(id: capture.id)
    #expect(try store.search("kestrel").isEmpty)
    #expect(try store.pending().map(\.sequence) == [1, 2, 3])
}

@Test func validationRejectsUnsafeLinksAndEmptyCaptures() {
    for value in [
        "file:///private/secret", "javascript:alert(1)", "https://",
        "https://user:pass@example.invalid",
    ] {
        #expect(throws: CaptureValidationError.self) {
            try CaptureInput.make(text: value, isLink: true)
        }
    }
    #expect(throws: CaptureValidationError.self) {
        try CaptureInput.make(text: " \n", isLink: false)
    }
}

@Test func offlineAndUnconfiguredNeverClearSharedPending() async throws {
    let f = Fixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.url)
    try store.save(CaptureInput.make(text: "Local source", isLink: false))
    #expect(try await MobileSyncCoordinator(store: store).sync() == .unconfigured)
    #expect(
        try await MobileSyncCoordinator(store: store, adapter: TestAdapter(.offline)).sync()
            == .offline)
    #expect(try store.pending().count == 1)
}

@Test func droppedAckReopenAndOwnEchoPreserveExactOperationThenRetryOnce() async throws {
    let f = Fixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.url)
    let server = try f.server()
    let capture = try CaptureInput.make(text: "Synthetic acknowledgement source", isLink: false)
    try store.save(capture)
    let original = try store.pending()
    let dropping = DroppedAcknowledgement(server)
    let coordinator = MobileSyncCoordinator(
        store: store, adapter: TestAdapter(.ready, transport: dropping))
    await #expect(throws: SyncError.acknowledgementLost) { try await coordinator.sync() }
    let reopened = try MobileStore(url: f.url)
    #expect(try reopened.pending() == original)
    #expect(reopened.deviceID == store.deviceID)
    try reopened.pull(from: server)
    #expect(try reopened.capture(id: capture.id)?.seenCount == 1)
    #expect(try reopened.pending() == original)
    try reopened.push(to: server)
    #expect(try reopened.pending().isEmpty)
    #expect(try server.baseline().captures.count == 1)
    #expect(try server.baseline().captures.first?.seenCount == 1)
    #expect(try server.changes(after: 0).changes.count == 1)
}

@Test(arguments: [false, true])
func deduplicatedDetailResolvesOriginalIDAcrossReopenAndDeletion(learnFromFeed: Bool) throws {
    let f = Fixture()
    defer { f.clean() }
    let mobile = try MobileStore(url: f.url)
    let mac = try f.mac()
    let server = try f.server()
    let local = try CaptureInput.make(text: "Synthetic duplicated source", isLink: false)
    let canonical = SharedCapture(
        source: CaptureSource(
            kind: .text,
            contentHash: CaptureFingerprint.contentHash(for: Data(local.selection.utf8)),
            title: "Existing authority source", selection: local.selection))
    try mac.enqueue(captureID: canonical.id, mutation: .create(canonical))
    try mac.push(to: server)
    try mobile.save(local)
    #expect(try mobile.capture(id: local.id)?.id == local.id)
    #expect(try mobile.capture(id: UUID()) == nil)
    if learnFromFeed {
        _ = try server.apply(#require(mobile.pending().first))
        try mobile.pull(from: server)
    } else {
        try mobile.push(to: server)
    }
    #expect(try mobile.search().map(\.id) == [canonical.id])
    let detail = try #require(try mobile.capture(id: local.id))
    #expect(detail.id == canonical.id)
    #expect(detail.title == "Existing authority source")
    let reopened = try MobileStore(url: f.url)
    #expect(try reopened.capture(id: local.id) == reopened.capture(id: canonical.id))
    try reopened.push(to: server)
    try reopened.update(id: local.id, note: "Edit from retained detail", tags: ["manual"])
    #expect(try reopened.pending().first?.captureID == canonical.id)
    try reopened.push(to: server)
    #expect(try reopened.capture(id: local.id)?.note == "Edit from retained detail")
    try reopened.delete(id: local.id)
    #expect(try reopened.capture(id: local.id) == nil)
    #expect(try reopened.capture(id: canonical.id) == nil)
    try reopened.push(to: server)
    #expect(try server.baseline().captures.first?.deleted == true)
}

@Test func pendingMobileNoteOverlayAndSeparateTagsSurviveMacPullAndConflict() throws {
    let f = Fixture()
    defer { f.clean() }
    let mobile = try MobileStore(url: f.url)
    let mac = try f.mac()
    let server = try f.server()
    let capture = try CaptureInput.make(
        text: "Synthetic shared source", note: "Original", isLink: false)
    try mobile.save(capture)
    try mobile.push(to: server)
    try mac.pull(from: server)
    try mobile.update(id: capture.id, note: "iPhone note", tags: ["manual"])
    let pending = try mobile.pending()
    try mac.enqueue(
        captureID: capture.id,
        mutation: .edit(
            CaptureEdit(
                note: NoteEdit("Mac note"),
                generated: GeneratedContent(body: "Generated source body", tags: ["generated"]))))
    try mac.push(to: server)
    try mobile.pull(from: server)
    #expect(try mobile.capture(id: capture.id)?.note == "iPhone note")
    #expect(try mobile.pending() == pending)
    #expect(try mobile.capture(id: capture.id)?.generatedTags == ["generated"])
    #expect(try mobile.capture(id: capture.id)?.manualTags == ["manual"])
    try mobile.push(to: server)
    let conflicted = try #require(try mobile.capture(id: capture.id))
    #expect(Set(conflicted.noteConflicts.compactMap(\.value)) == ["iPhone note", "Mac note"])
    try mobile.update(
        id: capture.id, note: "Both notes", tags: ["manual", "second"],
        resolving: conflicted.noteConflicts.map(\.operationID))
    try mobile.push(to: server)
    try mac.pull(from: server)
    let accepted = try #require(mac.captures().first)
    #expect(accepted.note == "Both notes")
    #expect(accepted.noteConflicts.isEmpty)
    #expect(accepted.manualTags == ["manual", "second"])
    #expect(accepted.generated.tags == ["generated"])
    try mobile.delete(id: capture.id)
    try mobile.push(to: server)
    try mac.pull(from: server)
    #expect(try mac.captures().isEmpty)
    #expect(try mobile.search().isEmpty)
    #expect(try server.baseline().captures.first?.deleted == true)
}

@Test func sourceProjectionFailureRollsBackQueueSequenceAndAck() throws {
    let f = Fixture()
    defer { f.clean() }
    let mobile = try MobileStore(url: f.url)
    let database = try DatabaseQueue(path: f.url.path)
    try database.write { db in
        try db.execute(
            sql:
                "CREATE TRIGGER abort_mobile_insert BEFORE INSERT ON mobile_captures BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END"
        )
    }
    let capture = try CaptureInput.make(text: "Synthetic atomic source", isLink: false)
    #expect(throws: (any Error).self) { try mobile.save(capture) }
    #expect(try mobile.pending().isEmpty)
    #expect(try mobile.search().isEmpty)
    try database.write { db in try db.execute(sql: "DROP TRIGGER abort_mobile_insert") }
    try mobile.save(capture)
    #expect(try mobile.pending().first?.sequence == 1)
    let server = try f.server()
    try database.write { db in
        try db.execute(
            sql:
                "CREATE TRIGGER abort_mobile_update BEFORE UPDATE ON mobile_captures BEGIN SELECT RAISE(ABORT, 'synthetic ACK failure'); END"
        )
    }
    let original = try mobile.pending()
    #expect(throws: (any Error).self) { try mobile.push(to: server) }
    #expect(try mobile.pending() == original)
    #expect(try server.baseline().captures.count == 1)
    try database.write { db in try db.execute(sql: "DROP TRIGGER abort_mobile_update") }
    try mobile.push(to: server)
    #expect(try mobile.pending().isEmpty)
    #expect(try server.changes(after: 0).changes.count == 1)
}

private final class ShareDuringSend: SyncTransport, @unchecked Sendable {
    let server: SyncServer
    let share: MobileStore
    private let lock = NSLock()
    private var inserted = false
    init(server: SyncServer, share: MobileStore) {
        self.server = server
        self.share = share
    }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        let receipt = try server.apply(operation)
        let shouldInsert = lock.withLock {
            let result = !inserted
            inserted = true
            return result
        }
        if shouldInsert {
            try share.save(CaptureInput.make(text: "Synthetic share during sync", isLink: false))
        }
        return receipt
    }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try server.changes(after: cursor, limit: limit)
    }
    func baseline() throws -> Baseline { try server.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try server.download(blob) }
}

@Test func extensionWriteDuringSyncRetainsItsOperationAndCountsOnlyActualReceipts() async throws {
    let f = Fixture()
    defer { f.clean() }
    let app = try MobileStore(url: f.url)
    let share = try MobileStore(url: f.url)
    let server = try f.server()
    try app.save(CaptureInput.make(text: "Synthetic first source", isLink: false))
    let coordinator = MobileSyncCoordinator(
        store: app,
        adapter: TestAdapter(.ready, transport: ShareDuringSend(server: server, share: share)))
    #expect(try await coordinator.sync() == .sent(1, rejected: 0))
    #expect(try app.pending().count == 1)
    #expect(try app.pending().first?.sequence == 2)
    #expect(try app.search().count == 2)
    #expect(try await coordinator.sync() == .sent(1, rejected: 0))
    #expect(try app.pending().isEmpty)
    #expect(try server.baseline().captures.count == 2)
}

@Test func staleAnnotationDraftUsesObservedRevisionAndDoesNotRemoveUnseenTags() throws {
    let f = Fixture()
    defer { f.clean() }
    let mobile = try MobileStore(url: f.url)
    let mac = try f.mac()
    let server = try f.server()
    let source = try CaptureInput.make(
        text: "Synthetic draft source", note: "Initial", isLink: false)
    try mobile.save(source)
    try mobile.push(to: server)
    let observed = try #require(try mobile.capture(id: source.id))
    try mac.pull(from: server)
    try mac.enqueue(
        captureID: source.id,
        mutation: .edit(CaptureEdit(note: NoteEdit("Mac update"), addTags: ["mac"])))
    try mac.push(to: server)
    try mobile.pull(from: server)
    try mobile.update(observed, note: observed.note, tags: ["phone"])
    try mobile.push(to: server)
    #expect(try mobile.capture(id: source.id)?.note == "Mac update")
    #expect(try mobile.capture(id: source.id)?.manualTags == ["mac", "phone"])
    try mobile.update(observed, note: "Draft typed earlier", tags: ["phone"])
    #expect(try mobile.pending().first?.baseRevision == observed.revision)
    try mobile.push(to: server)
    let variants = try mobile.capture(id: source.id)?.noteConflicts.compactMap(\.value) ?? []
    #expect(Set(variants) == ["Mac update", "Draft typed earlier"])
    #expect(try mobile.capture(id: source.id)?.manualTags == ["mac", "phone"])
}
