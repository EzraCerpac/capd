import Foundation
import Testing

@testable import CapdMobile
@testable import CapdSync

@Test func libraryRevisionTracksShareSavePullAcknowledgementAndRejection() async throws {
    let fixture = try LibraryRevisionFixture()
    defer { fixture.clean() }
    let store = fixture.store
    let share = try MobileStore(url: fixture.url)
    let initial = try store.libraryRevision()
    let source = try CaptureInput.make(text: "Saved revision source", isLink: false)
    try store.save(source)
    let local = try store.libraryRevision()
    #expect(local != initial && local.sequence == 1 && local.pendingChanges == 1)
    try share.save(CaptureInput.make(text: "Shared revision source", isLink: false))
    let shared = try store.libraryRevision()
    #expect(shared != local && shared.sequence == 2 && shared.pendingChanges == 2)
    try store.push(to: fixture.server)
    let acknowledged = try store.libraryRevision()
    #expect(acknowledged != shared && acknowledged.pendingChanges == 0)
    #expect(acknowledged.cursor == shared.cursor && acknowledged.sequence == shared.sequence)
    try store.pull(from: fixture.server)
    let pulled = try store.libraryRevision()
    #expect(pulled != acknowledged && pulled.cursor == 2)
    #expect(try store.libraryRevision() == pulled)
    try store.delete(id: source.id)
    let pendingDelete = try store.libraryRevision()
    try store.push(to: RejectedRevisionTransport(server: fixture.server))
    let rejected = try store.libraryRevision()
    #expect(rejected != pendingDelete)
    #expect(rejected.sequence == 3 && rejected.pendingChanges == 0 && rejected.rejectedChanges == 1)
    #expect(try store.capture(id: source.id) != nil)
    let controller = AutomaticSyncController(store: store)
    let state = await controller.currentState()
    #expect(state.libraryRevision == rejected)
    #expect(state.pendingChanges == 0 && state.rejectedChanges == 1)
}

@Test func statusOnlyEmissionsAndIdlePollsKeepTheLoadedLibraryRevision() async throws {
    let fixture = try LibraryRevisionFixture()
    defer { fixture.clean() }
    let loaded = try fixture.store.libraryRevision()
    let recorder = LibraryRevisionRecorder()
    let controller = AutomaticSyncController(
        store: fixture.store, adapter: RevisionReadyAdapter(server: fixture.server),
        policy: AutomaticSyncPolicy(foregroundPullInterval: 0.25), jitter: { 1 })
    let stream = await controller.states()
    let observer = Task {
        for await state in stream { await recorder.record(state) }
    }
    defer { observer.cancel() }
    await controller.foreground()
    for _ in 0..<200 {
        if await recorder.successfulPolls() >= 2 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    await controller.suspend()
    for _ in 0..<100 {
        if await recorder.hasPausedAfterSuccess() { break }
        await Task.yield()
    }
    let revisions = await recorder.revisions()
    #expect(await recorder.successfulPolls() >= 2)
    #expect(await recorder.hasPhase(.syncing))
    #expect(await recorder.hasPausedAfterSuccess())
    #expect(revisions.count >= 6)
    #expect(revisions.allSatisfy { $0 == loaded })
    #expect(try fixture.store.search().isEmpty)
}

@Test func conflictCountsFollowAcknowledgementsAndExplicitResolution() async throws {
    let fixture = try LibraryRevisionFixture()
    defer { fixture.clean() }
    let store = fixture.store
    let source = try CaptureInput.make(text: "Conflict revision source", isLink: false)
    try store.save(source)
    try store.push(to: fixture.server)
    try store.pull(from: fixture.server)
    let controller = AutomaticSyncController(store: store)
    #expect(await controller.currentState().conflictCount == 0)
    let observed = try #require(try store.capture(id: source.id))
    try store.update(observed, note: "Local variant", tags: [])
    _ = try fixture.server.apply(
        SyncOperation(
            deviceID: UUID(), sequence: 1, captureID: source.id,
            baseRevision: observed.revision,
            mutation: .edit(CaptureEdit(note: NoteEdit("Remote variant")))))
    try store.push(to: fixture.server)
    let conflict = await controller.currentState()
    #expect(conflict.conflictCount == 1)
    #expect(conflict.pendingChanges == 0)
    #expect(await controller.currentState().libraryRevision == conflict.libraryRevision)
    let unresolved = try #require(try store.capture(id: source.id))
    #expect(unresolved.noteConflicts.count == 2)
    try store.update(
        unresolved, note: "Chosen variant", tags: [],
        resolving: unresolved.noteConflicts.map(\.operationID))
    let resolved = await controller.currentState()
    #expect(resolved.libraryRevision != conflict.libraryRevision)
    #expect(resolved.conflictCount == 0 && resolved.pendingChanges == 1)
}

private struct LibraryRevisionFixture {
    let root: URL
    let url: URL
    let store: MobileStore
    let server: SyncServer
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        url = root.appendingPathComponent("mobile.sqlite")
        store = try MobileStore(url: url)
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-blobs"))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct RevisionReadyAdapter: MobileSyncAdapter {
    let server: SyncServer
    func availability() -> SyncAvailability { .ready }
    func transport() -> (any SyncTransport)? { server }
}

private actor LibraryRevisionRecorder {
    private var states: [AutomaticSyncState] = []
    func record(_ state: AutomaticSyncState) { states.append(state) }
    func revisions() -> [MobileLibraryRevision?] { states.map(\.libraryRevision) }
    func hasPhase(_ phase: AutomaticSyncState.Phase) -> Bool {
        states.contains { $0.phase == phase }
    }
    func successfulPolls() -> Int { Set(states.compactMap(\.lastSuccessfulSync)).count }
    func hasPausedAfterSuccess() -> Bool {
        states.contains { $0.phase == .paused && $0.lastSuccessfulSync != nil }
    }
}

private struct RejectedRevisionTransport: SyncTransport {
    let server: SyncServer
    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        SyncReceipt(operationID: operation.id, outcome: .missing, capture: nil)
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
