import CapdKit
import CapdSync
import Foundation
import GRDB
import Synchronization
import Testing

@testable import CapdAgent
@testable import CapdKit

@Suite("Agent generation freshness")
struct AgentGenerationTests {
    @Test func offlineOrdinaryStepFailureIsRequeuedBeforeFailurePublication() async throws {
        let fixture = try await GenerationFixture()
        defer { fixture.clean() }
        let latch = GenerationLatch()
        let work = Task { try await fixture.enrichment(latch: latch, failing: true).processNext() }
        await latch.waitForStart()
        await fixture.wire.setOffline(true)
        try fixture.editRemote(.init(generatedPatch: .init(body: .set("Healthy remote body"))))
        await latch.release()
        let result = await work.result
        if case .failure(let error) = result {
            #expect(error is GenerationGateError)
        } else {
            Issue.record("Expected a blocked ordinary failure")
        }
        #expect(try fixture.capture().enrichmentState == .pending)
        #expect(try fixture.pending().isEmpty)
        await fixture.wire.setOffline(false)
        #expect((await fixture.runtime.sync()).pullSucceeded)
        #expect(try fixture.capture().body == "Healthy remote body")
        #expect(try fixture.capture().enrichmentState == .ok)
    }

    @Test func observedRemoteChangeRejectsAwaitedCompletion() async throws {
        let fixture = try await GenerationFixture()
        defer { fixture.clean() }
        let latch = GenerationLatch()
        let work = Task { try await fixture.enrichment(latch: latch).processNext() }
        await latch.waitForStart()
        try fixture.editRemote(.init(generatedPatch: .init(body: .set("New observed body"))))
        await latch.release()
        await #expect(throws: GenerationGateError.self) { try await work.value }
        #expect(try fixture.capture().body == "New observed body")
        #expect(try fixture.pending().isEmpty)
    }

    @Test func cancellationRequeuesWithoutPublishing() async throws {
        let fixture = try await GenerationFixture()
        defer { fixture.clean() }
        let latch = GenerationLatch()
        let work = Task { try await fixture.enrichment(latch: latch).processNext() }
        await latch.waitForStart()
        work.cancel()
        await latch.release()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try fixture.capture().enrichmentState == .pending)
        #expect(try fixture.pending().isEmpty)
    }

    @Test func busyRuntimeDoesNotClaimAndQueueCallsDoNotOverlap() async throws {
        let fixture = try await GenerationFixture()
        defer { fixture.clean() }
        let latch = GenerationLatch()
        let queue = EnrichmentQueue(
            enrichment: fixture.enrichment(latch: latch), isOnMainsPower: { false })
        let lease = try #require(try MacSyncLease.acquire(paths: fixture.store.paths))
        await queue.drain()
        #expect(await latch.calls == 0)
        #expect(try fixture.capture().enrichmentState == .pending)
        withExtendedLifetime(lease) {}
    }

    @Test func simultaneousQueueDrainDoesNotDuplicateWork() async throws {
        let fixture = try await GenerationFixture()
        defer { fixture.clean() }
        let latch = GenerationLatch()
        let queue = EnrichmentQueue(
            enrichment: fixture.enrichment(latch: latch), isOnMainsPower: { false })
        let work = Task { await queue.drain() }
        await latch.waitForStart()
        await queue.drain()
        #expect(await latch.calls == 1)
        await latch.release()
        await work.value
        #expect(await latch.calls == 1)
        #expect(try fixture.capture().body == "Stale generated body")
    }

    @Test func taxonomyBatchStopsAfterAnIndependentSourceWrite() async throws {
        let fixture = try await GenerationFixture(kind: .text, count: 3)
        defer { fixture.clean() }
        let captures = try await fixture.store.reader.read {
            try Capture.fetchAll($0, sql: "SELECT * FROM captures ORDER BY id")
        }
        for capture in captures {
            try fixture.store.completeTagging(
                id: capture.id!, tags: ["old"],
                taxonomy: Taxonomy(tags: ["old"], updatedAt: .distantPast))
        }
        #expect((await fixture.runtime.sync()).pullSucceeded)
        let snapshot = try fixture.store.tagGenerationSnapshot()
        var revised = snapshot.taxonomy
        revised.version += 1
        revised.tags = ["new"]
        let peer = try Store(paths: fixture.store.paths, syncBinding: fixture.wire.binding)
        let observer = GenerationInterleaver(peer: peer, id: captures[1].id!)
        fixture.store.dbPool.add(transactionObserver: observer)
        #expect(throws: GenerationGateError.self) {
            try fixture.store.applyTaxonomyRevision(
                mapping: ["old": "new"], taxonomy: revised, batchSize: 1,
                expectedGeneration: snapshot)
        }
        #expect(observer.result.withLock { $0 == "injected" })
        let current = try await fixture.store.reader.read {
            try Capture.fetchAll($0, sql: "SELECT * FROM captures ORDER BY id")
        }
        #expect(current[0].tagList == ["new"])
        #expect(current[1].tagList == ["old"] && current[1].note == "Independent input")
        #expect(current[2].tagList == ["old"])
        #expect(try fixture.store.taxonomy() == snapshot.taxonomy)
        #expect(try fixture.pending().count == 2)
        #expect(
            try fixture.pending().map(\.sequence) == [
                snapshot.sequence! + 1, snapshot.sequence! + 2,
            ])
    }

    @Test func guardedTaxonomyBatchesAdvanceTheirOwnSequence() async throws {
        let fixture = try await GenerationFixture(kind: .text, count: 3)
        defer { fixture.clean() }
        for capture in try await fixture.store.reader.read({ try Capture.fetchAll($0) }) {
            try fixture.store.completeTagging(
                id: capture.id!, tags: ["old"],
                taxonomy: Taxonomy(tags: ["old"], updatedAt: .distantPast))
        }
        #expect((await fixture.runtime.sync()).pullSucceeded)
        let snapshot = try fixture.store.tagGenerationSnapshot()
        var revised = snapshot.taxonomy
        revised.version += 1
        revised.tags = ["new"]
        try fixture.store.applyTaxonomyRevision(
            mapping: ["old": "new"], taxonomy: revised, batchSize: 1,
            expectedGeneration: snapshot)
        #expect(try fixture.store.taxonomy() == revised)
        #expect(try fixture.pending().count == 3)
        #expect(
            try await fixture.store.reader.read {
                try Capture.fetchAll($0).allSatisfy { $0.tagList == ["new"] }
            })
    }

    @Test func laterOfflineDrainDoesNotClaimWork() async throws {
        let fixture = try await GenerationFixture()
        defer { fixture.clean() }
        let latch = GenerationLatch(held: false)
        let service = fixture.enrichment(latch: latch)
        await fixture.wire.setOffline(true)
        #expect(!(await fixture.runtime.sync()).pullSucceeded)
        await EnrichmentQueue(enrichment: service, isOnMainsPower: { false }).drain()
        #expect(await latch.calls == 0)
        #expect(try service.pendingCount() == 1)
        #expect(try fixture.pending().isEmpty)
    }

    @Test func offlineCompletionIsRequeuedAndRecoveryObservesRemoteBody() async throws {
        let fixture = try await GenerationFixture()
        defer { fixture.clean() }
        let latch = GenerationLatch()
        let service = fixture.enrichment(latch: latch)
        let work = Task {
            await EnrichmentQueue(enrichment: service, isOnMainsPower: { false }).drain()
        }
        await latch.waitForStart()
        await fixture.wire.setOffline(true)
        try fixture.editRemote(.init(generatedPatch: .init(body: .set("New remote body"))))
        await latch.release()
        await work.value
        #expect(try fixture.capture().body == nil)
        #expect(try fixture.capture().enrichmentState == .pending)
        #expect(try fixture.pending().isEmpty)
        await fixture.wire.setOffline(false)
        #expect((await fixture.runtime.sync()).pullSucceeded)
        await EnrichmentQueue(enrichment: service, isOnMainsPower: { false }).drain()
        #expect(await latch.calls == 1)
        #expect(try fixture.capture().body == "New remote body")
        #expect(try fixture.pending().isEmpty)
        #expect(try fixture.server.baseline().captures.first?.generated.body == "New remote body")
    }

    @Test func offlineTaggingDoesNotPublishAndRetriesNewInput() async throws {
        let fixture = try await GenerationFixture(kind: .text)
        defer { fixture.clean() }
        let latch = GenerationLatch()
        let tagging = fixture.tagging(latch: latch)
        let work = Task { try await tagging.tagNext() }
        await latch.waitForStart()
        await fixture.wire.setOffline(true)
        try fixture.editRemote(.init(note: NoteEdit("New remote input")))
        await latch.release()
        let result = await work.result
        if case .success = result { Issue.record("Offline generation was published") }
        #expect(try fixture.capture().tagsVersion == 0)
        #expect(try fixture.pending().isEmpty)
        await fixture.wire.setOffline(false)
        #expect((await fixture.runtime.sync()).pullSucceeded)
        #expect(try await fixture.tagging(latch: GenerationLatch(held: false)).tagNext() == 1)
        #expect(try fixture.capture().note == "New remote input")
    }

    @Test func offlineConsolidationDoesNotPublishTaxonomyOrGeneratedTags() async throws {
        let fixture = try await GenerationFixture(kind: .text, count: 2)
        defer { fixture.clean() }
        let captures = try await fixture.store.reader.read { try Capture.fetchAll($0) }
        for (index, capture) in captures.enumerated() {
            try fixture.store.completeTagging(
                id: capture.id!, tags: [index == 0 ? "first" : "second"],
                taxonomy: Taxonomy(
                    tags: ["first", "second"], taggedSinceConsolidation: 25,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        }
        #expect((await fixture.runtime.sync()).pullSucceeded)
        let taxonomy = try fixture.store.taxonomy()
        let latch = GenerationLatch()
        let work = Task { try await fixture.tagging(latch: latch).consolidateIfNeeded() }
        await latch.waitForStart()
        await fixture.wire.setOffline(true)
        try fixture.editRemote(.init(generatedPatch: .init(tags: ["remote"])))
        await latch.release()
        let result = await work.result
        if case .success = result { Issue.record("Offline taxonomy was published") }
        #expect(try fixture.store.taxonomy() == taxonomy)
        #expect(try fixture.pending().isEmpty)
        await fixture.wire.setOffline(false)
        #expect((await fixture.runtime.sync()).pullSucceeded)
        #expect(try fixture.capture().tagList == ["remote"])
    }
}

private final class GenerationInterleaver: TransactionObserver {
    let peer: Store
    let id: Int64
    let result = Mutex("waiting")
    private var changed = false
    init(peer: Store, id: Int64) {
        self.peer = peer
        self.id = id
    }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        eventKind.tableName == "captures"
    }
    func databaseDidChange(with event: DatabaseEvent) { changed = true }
    func databaseDidCommit(_ db: Database) {
        guard changed, result.withLock({ $0 == "waiting" }) else { return }
        result.withLock { $0 = "injecting" }
        do {
            _ = try peer.updateNote(id: id, note: "Independent input")
            result.withLock { $0 = "injected" }
        } catch {
            result.withLock { $0 = "failed: \(error)" }
        }
    }
    func databaseDidRollback(_ db: Database) { changed = false }
}

private struct GenerationFixture: Sendable {
    let root: URL
    let store: Store
    let runtime: MacSyncRuntime
    let server: SyncServer
    let wire: GenerationWire
    let remote: UUID
    let captureID: UUID

    init(kind: CaptureSource.Kind = .link, count: Int = 1) async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capd-generation-\(UUID())")
        let paths = StoragePaths(root: root.appendingPathComponent("library"))
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let device = UUID()
        remote = UUID()
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        var ids: [UUID] = []
        for index in 0..<count {
            let record = SharedCapture(
                source: CaptureSource(
                    kind: kind, contentHash: "generation-\(index)",
                    url: kind == .link ? "https://example.invalid/\(index)" : nil,
                    selection: kind == .text ? "Synthetic input \(index)" : nil),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            ids.append(record.id)
            _ = try server.apply(
                SyncOperation(
                    deviceID: remote, sequence: Int64(index + 1), captureID: record.id,
                    baseRevision: 0, mutation: .create(record)))
        }
        captureID = ids[0]
        let enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.invalid/v1/sync")!,
            binding: binding, deviceID: device)
        let credentials = MemorySyncCredentialStore()
        try credentials.save("synthetic-generation", for: enrollment)
        wire = GenerationWire(
            binding: binding, deviceID: device,
            handler: SyncHTTPHandler(
                serviceID: binding.serviceID,
                authorizer: GenerationAuthorizer(
                    principal: SyncPrincipal(
                        serviceID: binding.serviceID, libraryID: binding.libraryID,
                        deviceID: device)), server: { [server] _ in server }))
        let session = try await MacLibrarySession.activate(
            paths: paths, configuration: MacSyncConfiguration(enrollment: enrollment),
            credentials: credentials, transport: wire)
        store = session.store
        runtime = try #require(session.runtime)
        #expect((await runtime.sync()).pullSucceeded)
    }

    func enrichment(latch: GenerationLatch, failing: Bool = false) -> EnrichmentService {
        EnrichmentService(
            store: store, steps: [GenerationStep(latch: latch, failing: failing)],
            generationGate: CapdAgent.generationGate(runtime))
    }

    func tagging(latch: GenerationLatch) -> TagService {
        TagService(
            store: store, tagger: GenerationTagger(latch: latch),
            generationGate: CapdAgent.generationGate(runtime))
    }

    func capture() throws -> Capture {
        try #require(
            try store.reader.read {
                try Capture.fetchOne(
                    $0,
                    sql:
                        "SELECT captures.* FROM captures JOIN sync_capture_ids ON captures.id=local_id WHERE global_id=?",
                    arguments: [captureID.uuidString])
            })
    }

    func pending() throws -> [SyncOperation] { try store.syncClient!.pendingOperations() }

    func editRemote(_ edit: CaptureEdit) throws {
        let baseline = try server.baseline()
        let record = try #require(baseline.captures.first { $0.id == captureID })
        _ = try server.apply(
            SyncOperation(
                deviceID: remote, sequence: (baseline.deviceSequences[remote] ?? 0) + 1,
                captureID: captureID, baseRevision: record.revision, mutation: .edit(edit)))
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct GenerationAuthorizer: SyncAuthorizer {
    let principal: SyncPrincipal
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        bearerCredential == "synthetic-generation" ? principal : nil
    }
}

private actor GenerationWire: AsyncSyncTransport {
    nonisolated let binding: SyncLibraryBinding
    nonisolated let deviceID: UUID
    let handler: SyncHTTPHandler
    private var offline = false
    init(binding: SyncLibraryBinding, deviceID: UUID, handler: SyncHTTPHandler) {
        self.binding = binding
        self.deviceID = deviceID
        self.handler = handler
    }
    func setOffline(_ offline: Bool) { self.offline = offline }
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        if offline { throw SyncError.transportDisconnected }
        return handler.handle(request)
    }
}

private actor GenerationLatch {
    private let held: Bool
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    private(set) var calls = 0
    init(held: Bool = true) {
        self.held = held
        (started, startedContinuation) = AsyncStream.makeStream()
        (released, releaseContinuation) = AsyncStream.makeStream()
    }
    func run() async throws {
        calls += 1
        startedContinuation.yield(())
        if held {
            var iterator = released.makeAsyncIterator()
            _ = await iterator.next()
        }
        try Task.checkCancellation()
    }
    func waitForStart() async {
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
    }
    func release() {
        releaseContinuation.yield(())
        releaseContinuation.finish()
    }
}

private struct GenerationStep: ProcessingStep {
    let latch: GenerationLatch
    var failing = false
    func applies(to capture: Capture) -> Bool { capture.kind == .link }
    func run(_ capture: Capture, context: ProcessingContext) async throws -> StepResult {
        try await latch.run()
        if failing { throw GenerationStepFailure.synthetic }
        return StepResult(
            bodyExtraction: .init(body: "Stale generated body", status: .ok, source: .fetch))
    }
}

private enum GenerationStepFailure: Error { case synthetic }

private struct GenerationTagger: Tagger {
    let latch: GenerationLatch
    func availability() -> TaggerAvailability { .available }
    func assignTags(_ input: TaggingInput, taxonomy: [String], mayInventNew: Bool) async throws
        -> [String]
    {
        try await latch.run()
        return ["generated"]
    }
    func planTaxonomy(_ samples: [TaggingInput], existing: [String]) async throws -> [String] {
        try await latch.run()
        return existing
    }
    func reviseTaxonomy(_ usage: [TagUsage]) async throws -> TaxonomyRevision {
        try await latch.run()
        return TaxonomyRevision(keep: ["merged"], merges: ["first": "merged", "second": "merged"])
    }
}
