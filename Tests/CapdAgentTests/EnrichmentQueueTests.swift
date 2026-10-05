import CapdKit
import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdAgent
@testable import CapdKit

@Suite("EnrichmentQueue")
struct EnrichmentQueueTests {
    @Test("Agent startup pulls remote content before claiming local enrichment")
    func initialSyncPrecedesEnrichment() async throws {
        try await withTemporaryPaths { paths in
            let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
            let device = UUID()
            let remoteDevice = UUID()
            let server = try SyncServer(
                databaseURL: paths.root.appendingPathComponent("authority.sqlite"),
                blobDirectory: paths.root.appendingPathComponent("authority-blobs"),
                libraryID: binding.libraryID, serviceID: binding.serviceID)
            let record = SharedCapture(
                source: CaptureSource(
                    kind: .link, contentHash: "startup", url: "https://example.invalid/startup"))
            try server.apply(
                SyncOperation(
                    deviceID: remoteDevice, sequence: 1, captureID: record.id,
                    baseRevision: 0, mutation: .create(record)))
            let enrollment = try SyncEnrollment(
                endpoint: URL(string: "https://sync.example.invalid/v1/sync")!,
                binding: binding, deviceID: device)
            let credentials = MemorySyncCredentialStore()
            try credentials.save("synthetic-agent-credential", for: enrollment)
            let wire = StartupWire(
                binding: binding, deviceID: device,
                handler: SyncHTTPHandler(
                    serviceID: binding.serviceID,
                    authorizer: StartupAuthorizer(
                        principal: SyncPrincipal(
                            serviceID: binding.serviceID, libraryID: binding.libraryID,
                            deviceID: device)),
                    server: { _ in server }))
            let session = try await MacLibrarySession.activate(
                paths: paths, configuration: MacSyncConfiguration(enrollment: enrollment),
                credentials: credentials, transport: wire)
            let runtime = try #require(session.runtime)
            #expect(await runtime.sync().phase == .idle)
            let enrichment = EnrichmentService(
                store: session.store, steps: [StartupStep(wire: wire)])
            #expect(try enrichment.pendingCount() == 1)
            try server.apply(
                SyncOperation(
                    deviceID: remoteDevice, sequence: 2, captureID: record.id,
                    baseRevision: 1,
                    mutation: .edit(CaptureEdit(generated: GeneratedContent(body: "Remote body")))))
            await wire.holdPull()
            let startup = Task {
                await CapdAgent.startSync(runtime)
                let queue = EnrichmentQueue(enrichment: enrichment, isOnMainsPower: { false })
                await queue.drain()
            }
            await wire.waitForPull()
            for _ in 0..<20 { await Task.yield() }
            #expect(await wire.enrichments == 0)
            await wire.releasePull()
            await startup.value
            await runtime.stop()
            #expect(await wire.enrichments == 0)
            #expect(try session.store.syncClient?.pendingOperations().isEmpty == true)
            let current = try #require(
                try await session.store.reader.read { try Capture.fetchOne($0) })
            #expect(current.body == "Remote body")
            #expect(current.enrichmentState == .ok)
            #expect(try server.baseline().captures.first?.generated.body == "Remote body")
        }
    }

    @Test("A 50-capture burst never exceeds three concurrent fetches on mains power")
    func burstStaysUnderTheMainsCap() async throws {
        try await withTemporaryPaths { paths in
            let store = try Store(paths: paths)
            try ingestLinks(50, into: store)

            let gauge = Gauge()
            let enrichment = EnrichmentService(store: store, steps: [GaugedStep(gauge: gauge)])
            let queue = EnrichmentQueue(enrichment: enrichment, isOnMainsPower: { true })

            await queue.drain()

            #expect(await gauge.peak <= DrainPolicy.mainsPowerWidth)
            #expect(await gauge.peak > 1)
            #expect(try EnrichmentService(store: store).pendingCount() == 0)
            #expect(try states(in: store) == [.ok])
        }
    }

    @Test("On battery the queue drains one capture at a time")
    func batteryDrainsSerially() async throws {
        try await withTemporaryPaths { paths in
            let store = try Store(paths: paths)
            try ingestLinks(10, into: store)

            let gauge = Gauge()
            let enrichment = EnrichmentService(store: store, steps: [GaugedStep(gauge: gauge)])
            let queue = EnrichmentQueue(enrichment: enrichment, isOnMainsPower: { false })

            await queue.drain()

            #expect(await gauge.peak == DrainPolicy.batteryWidth)
            #expect(try EnrichmentService(store: store).pendingCount() == 0)
        }
    }

    @Test("A throwing step fails its row without poisoning the queue")
    func throwingStepDoesNotPoisonTheQueue() async throws {
        try await withTemporaryPaths { paths in
            let store = try Store(paths: paths)
            let service = CaptureService(store: store)
            let bad = try #require(
                try service.ingest(CaptureRequest(url: "https://example.com/bad")).capture.id)
            let good = try #require(
                try service.ingest(CaptureRequest(url: "https://example.com/good")).capture.id)

            let enrichment = EnrichmentService(store: store, steps: [TrapStep()])
            let queue = EnrichmentQueue(enrichment: enrichment, isOnMainsPower: { false })

            // The first drain dies on the bad row; the second finishes the queue.
            await queue.drain()
            await queue.drain()

            #expect(try state(of: bad, in: store) == .failed)
            #expect(try state(of: good, in: store) == .ok)
        }
    }
}

private actor Gauge {
    private var active = 0
    private(set) var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func exit() {
        active -= 1
    }
}

private struct GaugedStep: ProcessingStep {
    let gauge: Gauge

    func applies(to capture: Capture) -> Bool {
        capture.kind == .link
    }

    func run(_ capture: Capture, context: ProcessingContext) async throws -> StepResult {
        await gauge.enter()
        try await Task.sleep(for: .milliseconds(10))
        await gauge.exit()
        return StepResult(
            bodyExtraction: BodyExtractionResult(body: "a body", status: .ok, source: .fetch))
    }
}

private struct TrapStep: ProcessingStep {
    struct Trap: Error {}

    func applies(to capture: Capture) -> Bool {
        capture.kind == .link
    }

    func run(_ capture: Capture, context: ProcessingContext) async throws -> StepResult {
        if capture.url?.hasSuffix("bad") == true {
            throw Trap()
        }
        return StepResult(
            bodyExtraction: BodyExtractionResult(body: "a body", status: .ok, source: .fetch))
    }
}

private func ingestLinks(_ count: Int, into store: Store) throws {
    let service = CaptureService(store: store)
    for index in 0..<count {
        _ = try service.ingest(CaptureRequest(url: "https://example.com/page-\(index)"))
    }
}

private func states(in store: Store) throws -> [EnrichmentState] {
    try store.reader.read { db in
        try Capture.fetchAll(db).map(\.enrichmentState)
    }.uniqued()
}

private func state(of id: Int64, in store: Store) throws -> EnrichmentState? {
    try store.reader.read { db in
        try Capture.fetchOne(db, key: id)?.enrichmentState
    }
}

extension [EnrichmentState] {
    fileprivate func uniqued() -> [EnrichmentState] {
        Array(Set(self)).sorted { $0.rawValue < $1.rawValue }
    }
}

private func withTemporaryPaths(_ body: (StoragePaths) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("capd-agent-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(StoragePaths(root: root))
}

private struct StartupAuthorizer: SyncAuthorizer {
    let principal: SyncPrincipal
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        bearerCredential == "synthetic-agent-credential" ? principal : nil
    }
}

private actor StartupWire: AsyncSyncTransport {
    nonisolated let binding: SyncLibraryBinding
    nonisolated let deviceID: UUID
    let handler: SyncHTTPHandler
    private var holding = false
    private let pulls: AsyncStream<Void>
    private let pullContinuation: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    var enrichments = 0
    init(binding: SyncLibraryBinding, deviceID: UUID, handler: SyncHTTPHandler) {
        self.binding = binding
        self.deviceID = deviceID
        self.handler = handler
        (pulls, pullContinuation) = AsyncStream.makeStream()
        (releases, releaseContinuation) = AsyncStream.makeStream()
    }
    func holdPull() { holding = true }
    func waitForPull() async {
        var iterator = pulls.makeAsyncIterator()
        _ = await iterator.next()
    }
    func releasePull() {
        holding = false
        releaseContinuation.yield(())
        releaseContinuation.finish()
    }
    func enriched() { enrichments += 1 }
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        let envelope = try JSONDecoder().decode(SyncHTTPEnvelope.self, from: request.body)
        if holding, case .changes = envelope.action {
            pullContinuation.yield(())
            var iterator = releases.makeAsyncIterator()
            _ = await iterator.next()
        }
        return handler.handle(request)
    }
}

private struct StartupStep: ProcessingStep {
    let wire: StartupWire
    func applies(to capture: Capture) -> Bool { capture.kind == .link }
    func run(_ capture: Capture, context: ProcessingContext) async throws -> StepResult {
        await wire.enriched()
        return StepResult(
            bodyExtraction: BodyExtractionResult(body: "Stale body", status: .ok, source: .fetch))
    }
}
