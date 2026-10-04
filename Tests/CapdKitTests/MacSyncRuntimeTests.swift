import CapdSync
import Darwin
import Foundation
import GRDB
import Testing

@testable import CapdKit

@Suite("Synthetic Mac runtime")
struct MacSyncRuntimeTests {
    @Test func optionalExistingLoopbackProxyPersistsWithoutChangingEnrollment() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let configuration = MacSyncConfiguration(enrollment: f.enrollment, loopbackSOCKSPort: 11080)
        _ = try await MacLibrarySession.activate(
            paths: f.paths, configuration: configuration,
            credentials: f.credentials, transport: f.wire)
        let loaded = try #require(try MacSyncConfiguration.load(paths: f.paths))
        #expect(loaded.loopbackSOCKSPort == 11080)
        #expect(try loaded.enrollment() == f.enrollment)
        #expect(try f.open().configuration == configuration)
        let legacy = try JSONDecoder().decode(
            MacSyncConfiguration.self, from: JSONEncoder().encode(f.configuration))
        #expect(legacy.loopbackSOCKSPort == nil)
        for port in [-1, 0, 65536] {
            #expect(throws: MacSyncError.invalidConfiguration) {
                try MacSyncConfiguration(enrollment: f.enrollment, loopbackSOCKSPort: port)
                    .enrollment()
            }
            #expect(throws: SyncConnectionError.invalidEndpoint) {
                try URLSessionSyncTransport(
                    endpoint: f.enrollment.endpoint, binding: f.binding, deviceID: f.device,
                    loopbackSOCKSPort: port)
            }
        }
        #expect(throws: SyncConnectionError.invalidEndpoint) {
            try URLSessionSyncTransport(
                endpoint: URL(string: "http://sync.example.invalid/v1/sync")!,
                binding: f.binding, deviceID: f.device, loopbackSOCKSPort: 11080)
        }
    }

    @Test func activeRuntimeRejectsProxyRouteChanges() async throws {
        let ports: [(Int?, Int?)] = [(nil, 11080), (11080, nil), (11080, 11081)]
        for (originalPort, changedPort) in ports {
            let f = try RuntimeFixture()
            defer { f.clean() }
            let session = try await MacLibrarySession.activate(
                paths: f.paths,
                configuration: MacSyncConfiguration(
                    enrollment: f.enrollment, loopbackSOCKSPort: originalPort),
                credentials: f.credentials, transport: f.wire)
            _ = try CaptureService(store: session.store).ingest(
                CaptureRequest(text: "Queued capture"))
            let pending = try await outbox(session.store)
            let requests = await f.wire.requests
            try MacSyncConfiguration(enrollment: f.enrollment, loopbackSOCKSPort: changedPort)
                .install(paths: f.paths)
            let status = await session.runtime!.sync()
            #expect(status.phase == .attention)
            #expect(status.issue?.contains("Reopen") == true)
            #expect(await f.wire.requests == requests)
            #expect(try await outbox(session.store) == pending)
        }
    }

    @Test func conflictingNotesStayVisibleAndNeedAttentionUntilResolved() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let remoteDevice = UUID()
        let remote = SharedCapture(
            source: CaptureSource(
                kind: .text, contentHash: "conflicting-note", title: "Note conflict"),
            createdAt: Date(), note: "Original note")
        _ = try f.server.apply(
            SyncOperation(
                deviceID: remoteDevice, sequence: 1, captureID: remote.id,
                baseRevision: 0, mutation: .create(remote)))
        let session = try await f.activate()
        #expect(await session.runtime!.sync().phase == .idle)
        let local = try #require(try await session.store.reader.read { try Capture.fetchOne($0) })
        _ = try session.store.updateNote(id: local.id!, note: "Mac variant")
        _ = try f.server.apply(
            SyncOperation(
                deviceID: remoteDevice, sequence: 2, captureID: remote.id,
                baseRevision: 1, mutation: .edit(CaptureEdit(note: NoteEdit("Remote variant")))))
        let status = await session.runtime!.sync()
        #expect(status.phase == .attention)
        #expect(status.rejected == 0)
        #expect(status.issue?.contains("Conflicting notes") == true)
        let conflict = try #require(status.noteConflicts.first)
        #expect(conflict.title == "Note conflict")
        #expect(Set(conflict.variants.compactMap(\.value)) == ["Mac variant", "Remote variant"])
        let encoded = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(MacSyncStatus.self, from: encoded) == status)
        #expect(await session.runtime!.sync().noteConflicts == status.noteConflicts)
        let reopened = try f.open()
        #expect(await reopened.runtime!.status().phase == .attention)
        #expect(try reopened.store.noteConflicts() == status.noteConflicts)
        await f.wire.setFault(.offline)
        let offline = await session.runtime!.sync()
        #expect(offline.phase == .attention)
        #expect(offline.noteConflicts == status.noteConflicts)
        await f.wire.setFault(.none)
        let current = try #require(try f.server.baseline().captures.first)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: remoteDevice, sequence: 3, captureID: remote.id,
                baseRevision: current.revision,
                mutation: .edit(
                    CaptureEdit(
                        note: NoteEdit(
                            "Resolved note", resolving: conflict.variants.map(\.operationID))))))
        let resolved = await session.runtime!.sync()
        #expect(resolved.phase == .idle)
        #expect(resolved.issue == nil)
        #expect(resolved.noteConflicts.isEmpty)
        #expect(
            try await session.store.reader.read { try Capture.fetchOne($0)?.note }
                == "Resolved note")
    }

    @Test func activationIsAtomicAndUnconfiguredStaysLocal() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let local = try MacLibrarySession.open(paths: f.paths)
        #expect(local.runtime == nil)
        await #expect(throws: RuntimeTestError.injected) {
            try await MacLibrarySession.activate(
                paths: f.paths, configuration: f.configuration,
                credentials: f.credentials, transport: f.wire,
                afterInstall: { db in
                    try db.execute(sql: "UPDATE sync_meta SET sequence=99")
                    throw RuntimeTestError.injected
                })
        }
        #expect(try MacSyncConfiguration.load(paths: f.paths) == nil)
        let untouched = try await local.store.reader.read { db in
            try !db.tableExists("sync_binding") && !db.tableExists("sync_meta")
        }
        #expect(untouched)
        #expect(
            !FileManager.default.fileExists(
                atPath: f.paths.assetsDirectory.appendingPathComponent("sync").path))
        let active = try await f.activate()
        #expect(active.store.syncClient?.deviceID == f.device)
        #expect(try MacSyncConfiguration.load(paths: f.paths) == f.configuration)
        let before = try MacSyncConfiguration.bytes(paths: f.paths)
        await #expect(throws: RuntimeTestError.injected) {
            try await MacLibrarySession.activate(
                paths: f.paths, configuration: f.configuration,
                credentials: f.credentials, transport: f.wire,
                afterInstall: { _ in throw RuntimeTestError.injected })
        }
        #expect(try MacSyncConfiguration.bytes(paths: f.paths) == before)
        #expect(try active.store.syncClient?.pendingOperations().isEmpty == true)
        try FileManager.default.removeItem(at: MacSyncConfiguration.url(paths: f.paths))
        #expect(throws: MacSyncError.configurationRequired) {
            try MacLibrarySession.open(paths: f.paths)
        }
        #expect(active.store.syncClient?.deviceID == f.device)
    }

    @Test func unsupportedProcessingAuthorityCannotActivate() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let local = try MacLibrarySession.open(paths: f.paths)
        await f.wire.setFault(.missingProcessing)
        await #expect(throws: SyncHTTPError.unsupportedVersion) { try await f.activate() }
        #expect(try MacSyncConfiguration.bytes(paths: f.paths) == nil)
        #expect(try await local.store.reader.read { try StoreSync.binding(in: $0) } == nil)
        #expect(try await local.store.reader.read { try !$0.tableExists("sync_meta") })
        #expect(await f.wire.applies == 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: f.paths.assetsDirectory.appendingPathComponent("sync").path))
        await f.wire.setFault(.none)
        let activated = try await f.activate()
        #expect(activated.store.syncClient?.deviceID == f.device)
    }

    @Test func credentialFailurePauseAndResumeKeepBoundWrites() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let active = try await f.activate()
        try f.credentials.remove(for: f.enrollment)
        let missing = try f.open()
        let initial = await missing.runtime!.status()
        #expect(initial.phase == .attention)
        #expect(initial.issue?.contains("credential") == true)
        _ = try CaptureService(store: missing.store).ingest(CaptureRequest(text: "Offline kestrel"))
        let bytes = try await outbox(missing.store)
        let failed = await missing.runtime!.sync()
        #expect(failed.phase == .attention)
        #expect(try await outbox(missing.store) == bytes)
        #expect(await f.wire.applies == 0)
        try await MacLibrarySession.setEnabled(false, paths: f.paths)
        let paused = await active.runtime!.sync()
        #expect(paused.phase == .paused)
        let reopened = try MacLibrarySession.open(paths: f.paths)
        #expect(reopened.store.syncClient?.deviceID == f.device)
        _ = try CaptureService(store: reopened.store).ingest(
            CaptureRequest(text: "Paused pangolin"))
        #expect(try reopened.store.syncClient?.pendingOperations().map(\.sequence) == [1, 2])
        try f.credentials.save(f.token, for: f.enrollment)
        try await MacLibrarySession.setEnabled(true, paths: f.paths)
        #expect(await active.runtime!.sync().phase == .idle)
        #expect(try active.store.syncClient?.pendingOperations().isEmpty == true)
        #expect(try f.server.baseline().captures.count == 2)
    }

    @Test func pulledPendingContentIsEnrichedTaggedAndNotEchoed() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let now = Date(timeIntervalSince1970: 1_700_000_000.123456789)
        let remote = SharedCapture(
            source: CaptureSource(
                kind: .link, contentHash: "remote-link",
                url: "https://example.invalid/source", host: "example.invalid",
                title: "Incoming kestrel"),
            createdAt: now,
            metadata: CaptureMetadata(
                updatedAt: now, lastSeenAt: now, sourceAppBundleID: "synthetic.phone"))
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: remote.id,
                baseRevision: 0, mutation: .create(remote)))
        let session = try await f.activate()
        #expect(await session.runtime!.sync().phase == .idle)
        let gauge = RuntimeGauge()
        let service = EnrichmentService(store: session.store, steps: [RuntimeStep(gauge: gauge)])
        #expect(try service.pendingCount() == 1)
        async let first = service.processNext()
        async let second = EnrichmentService(
            store: try f.open().store, steps: [RuntimeStep(gauge: gauge)]
        ).processNext()
        let results = try await [first, second]
        #expect(results.compactMap { $0 }.count == 1)
        #expect(await gauge.runs == 1)
        let tags = TagService(store: session.store, tagger: RuntimeTagger())
        #expect(try await tags.tagNext() == 1)
        #expect(await session.runtime!.sync().phase == .idle)
        let shared = try #require(try f.server.baseline().captures.first)
        #expect(shared.generated.body == "Synthetic pangolin body")
        #expect(shared.generated.tags == ["generated"])
        #expect(shared.createdAt == now)
        #expect(shared.metadata?.lastSeenAt == now)
        #expect(shared.metadata?.sourceAppBundleID == "synthetic.phone")
        #expect(try service.pendingCount() == 0)
        #expect(await session.runtime!.sync().phase == .idle)
        #expect(try await tags.tagNext() == 0)
        #expect(try await service.processNext() == nil)
        #expect(try session.store.syncClient?.pendingOperations().isEmpty == true)
        #expect(try SearchService(store: session.store).search("pangolin").count == 1)
    }

    @Test func offlineLostResponseCancellationAndRestartKeepExactOperations() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let session = try await f.activate()
        _ = try CaptureService(store: session.store).ingest(CaptureRequest(text: "Retry kestrel"))
        let bytes = try await outbox(session.store)
        await f.wire.setFault(.offline)
        #expect(await session.runtime!.sync().phase == .offline)
        #expect(try await outbox(session.store) == bytes)
        await f.wire.setFault(.hold)
        let cancelled = Task { await session.runtime!.sync() }
        try await f.wire.waitForRequest()
        cancelled.cancel()
        #expect(await cancelled.value.phase == .paused)
        #expect(try await outbox(session.store) == bytes)
        await f.wire.setFault(.lostApply)
        #expect(await session.runtime!.sync().phase == .offline)
        #expect(try await outbox(session.store) == bytes)
        #expect(try f.server.baseline().captures.count == 1)
        let reopened = try f.open()
        #expect(reopened.store.syncClient?.deviceID == f.device)
        #expect(await reopened.runtime!.sync().phase == .idle)
        #expect(try reopened.store.syncClient?.pendingOperations().isEmpty == true)
        #expect(try f.server.baseline().captures.first?.seenCount == 1)
        let bodies = await f.wire.applyBodies
        #expect(bodies.count == 2)
        #expect(bodies[0] == bodies[1])
    }

    @Test func advancedEmptyEnrollmentAndUnprocessedConsolidationFailClosed() async throws {
        let advanced = try RuntimeFixture()
        defer { advanced.clean() }
        let authorityRecord = SharedCapture(
            source: CaptureSource(kind: .text), createdAt: Date(), note: "Advanced device history")
        _ = try advanced.server.apply(
            SyncOperation(
                deviceID: advanced.device, sequence: 1, captureID: authorityRecord.id,
                baseRevision: 0, mutation: .create(authorityRecord)))
        await #expect(throws: SyncError.wrongDevice) { try await advanced.activate() }
        #expect(try MacSyncConfiguration.load(paths: advanced.paths) == nil)
        let unbound = try Store(paths: advanced.paths)
        #expect(try await unbound.reader.read { try StoreSync.binding(in: $0) } == nil)
        #expect(try SearchService(store: unbound).totalCaptureCount() == 0)

        let f = try RuntimeFixture()
        defer { f.clean() }
        var pending = SharedCapture(
            source: CaptureSource(kind: .text), createdAt: Date(), note: "Changed model input")
        pending.generated.tags = ["old"]
        pending.generated.taggingProcessed = false
        pending.manualTags = ["manual"]
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: pending.id,
                baseRevision: 0, mutation: .create(pending)))
        let session = try await f.activate()
        #expect(await session.runtime!.sync().phase == .idle)
        try session.store.applyTaxonomyRevision(
            mapping: ["old": "mapped"], taxonomy: Taxonomy(tags: ["mapped"], updatedAt: Date()))
        #expect(try session.store.untaggedCaptures(limit: 5).count == 1)
        #expect(await session.runtime!.sync().phase == .idle)
        #expect(try f.server.baseline().captures.first?.generated.taggingProcessed == false)
        #expect(try f.server.baseline().captures.first?.manualTags == ["manual"])
        #expect(
            try await TagService(store: session.store, tagger: RuntimeTagger(tags: [])).tagNext()
                == 1)
    }

    @Test func consolidationCountsAndPreservesMixedGeneratedCategories() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let session = try await f.activate()
        let service = CaptureService(store: session.store)
        _ = try service.ingest(CaptureRequest(text: "Mixed kestrel", tags: ["manual"]))
        _ = try service.ingest(CaptureRequest(text: "Mixed pangolin", tags: ["manual"]))
        for capture in try await session.store.reader.read({ try Capture.fetchAll($0) }) {
            try session.store.completeTagging(
                id: capture.id!,
                tags: [capture.selection?.contains("kestrel") == true ? "kestrel" : "pangolin"],
                taxonomy: Taxonomy(
                    tags: ["kestrel", "pangolin"], taggedSinceConsolidation: 25, updatedAt: Date()))
        }
        #expect(await session.runtime!.sync().phase == .idle)
        #expect(
            try session.store.tagUsage(includePinned: false).map(\.tag) == ["kestrel", "pangolin"])
        #expect(try session.store.tagUsage(includePinned: false).allSatisfy { $0.count == 1 })
        #expect(
            try await TagService(store: session.store, tagger: RuntimeTagger())
                .consolidateIfNeeded())
        #expect(await session.runtime!.sync().phase == .idle)
        let records = try f.server.baseline().captures
        #expect(records.allSatisfy { $0.manualTags == ["manual"] })
        #expect(Set(records.flatMap { $0.generated.tags }) == ["kestrel", "pangolin"])
        #expect(records.allSatisfy { $0.generated.taggingProcessed == true })
        #expect(try session.store.untaggedCaptures(limit: 5).isEmpty)
    }

    @Test func timeoutAndRejectionsSurfaceAttention() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let session = try await f.activate()
        _ = try CaptureService(store: session.store).ingest(
            CaptureRequest(text: "Deadline kestrel"))
        let bytes = try await outbox(session.store)
        await f.wire.setFault(.hold)
        let timed = await session.runtime!.sync(within: .milliseconds(50))
        #expect(timed.phase == .attention)
        #expect(timed.issue?.contains("timed out") == true)
        #expect(try await outbox(session.store) == bytes)
        await f.wire.setFault(.none)
        let operation = try #require(try session.store.syncClient?.pendingOperations().first)
        _ = try f.server.apply(operation)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: operation.captureID,
                baseRevision: 1, mutation: .delete))
        #expect(await session.runtime!.sync().phase == .idle)
        _ = try CaptureService(store: session.store).ingest(
            CaptureRequest(text: "Deadline kestrel"))
        let rejected = await session.runtime!.sync()
        #expect(rejected.phase == .attention)
        #expect(rejected.rejected == 1)
        #expect(rejected.issue?.contains("rejected") == true)
        #expect(try session.store.syncClient?.rejectedWork().count == 1)
    }

    @Test func processedEmptyTagsSurvivePullAndInvalidateOnInputsAndExplicitRetag() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let remoteDevice = UUID()
        var remote = SharedCapture(
            source: CaptureSource(kind: .text, contentHash: "empty-tag-input"),
            createdAt: Date(), note: "Original zero-tag text")
        remote.manualTags = ["manual"]
        remote.generated.taggingProcessed = false
        _ = try f.server.apply(
            SyncOperation(
                deviceID: remoteDevice, sequence: 1, captureID: remote.id,
                baseRevision: 0, mutation: .create(remote)))
        let session = try await f.activate()
        #expect(await session.runtime!.sync().phase == .idle)
        let tags = TagService(store: session.store, tagger: RuntimeTagger(tags: []))
        #expect(try await tags.tagNext() == 1)
        #expect(await session.runtime!.sync().phase == .idle)
        let processed = try #require(try f.server.baseline().captures.first)
        #expect(processed.generated.taggingProcessed == true)
        #expect(
            processed.generated.taggingInputFingerprint?.hasPrefix("capd-tagging-input-v1:") == true
        )
        #expect(processed.generated.tags.isEmpty)
        #expect(processed.manualTags == ["manual"])
        let reopened = try f.open()
        #expect(await reopened.runtime!.sync().phase == .idle)
        #expect(
            try await TagService(store: reopened.store, tagger: RuntimeTagger(tags: [])).tagNext()
                == 0)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: remoteDevice, sequence: 2, captureID: remote.id,
                baseRevision: processed.revision,
                mutation: .edit(CaptureEdit(note: NoteEdit("Changed input")))))
        #expect(await session.runtime!.sync().phase == .idle)
        #expect(try await tags.tagNext() == 1)
        #expect(await session.runtime!.sync().phase == .idle)
        try session.store.requestRetagging()
        #expect(try await tags.tagNext() == 1)
        #expect(await session.runtime!.sync().phase == .idle)
        #expect(try await tags.tagNext() == 0)
        #expect(try f.server.baseline().captures.first?.manualTags == ["manual"])
        #expect(try f.server.baseline().captures.first?.generated.taggingProcessed == true)
    }

    @Test func staleTaggingAndEnrichmentCannotOverwriteNewInputs() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let remoteDevice = UUID()
        let remote = SharedCapture(
            source: CaptureSource(
                kind: .link, contentHash: "racing-body",
                url: "https://example.invalid/race", title: "Body race"), createdAt: Date())
        _ = try f.server.apply(
            SyncOperation(
                deviceID: remoteDevice, sequence: 1, captureID: remote.id,
                baseRevision: 0, mutation: .create(remote)))
        let session = try await f.activate()
        #expect(await session.runtime!.sync().phase == .idle)
        let claimed = try #require(try session.store.claimNextForEnrichment())
        _ = try f.server.apply(
            SyncOperation(
                deviceID: remoteDevice, sequence: 2, captureID: remote.id,
                baseRevision: 1,
                mutation: .edit(
                    CaptureEdit(generated: GeneratedContent(body: "New authoritative body")))))
        #expect(await session.runtime!.sync().phase == .idle)
        let completed = try session.store.completeEnrichment(
            id: claimed.id!,
            result: StepResult(
                bodyExtraction: BodyExtractionResult(body: "Old body", status: .ok, source: .fetch)),
            state: .ok, expectedClaim: claimed)
        #expect(completed.body == "New authoritative body")
        #expect(try session.store.syncClient?.pendingOperations().isEmpty == true)
        let fingerprint = TaggingFingerprint.of(completed)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: remoteDevice, sequence: 3, captureID: remote.id,
                baseRevision: 2,
                mutation: .edit(CaptureEdit(note: NoteEdit("New tagging input")))))
        #expect(await session.runtime!.sync().phase == .idle)
        #expect(
            try !session.store.completeTagging(
                id: completed.id!, tags: ["stale"], taxonomy: session.store.taxonomy(),
                inputFingerprint: fingerprint))
        #expect(try session.store.syncClient?.pendingOperations().isEmpty == true)
        #expect(
            try await TagService(store: session.store, tagger: RuntimeTagger(tags: [])).tagNext()
                == 1)
        #expect(await session.runtime!.sync().phase == .idle)
        let previous = try #require(try f.server.baseline().captures.first)
        // An old client replaces body/tags without a descriptor; the server preserves it.
        _ = try f.server.apply(
            SyncOperation(
                deviceID: remoteDevice, sequence: 4, captureID: remote.id,
                baseRevision: previous.revision,
                mutation: .edit(
                    CaptureEdit(generated: GeneratedContent(body: "Old client changed body")))))
        #expect(await session.runtime!.sync().phase == .idle)
        #expect(
            try await TagService(store: session.store, tagger: RuntimeTagger(tags: [])).tagNext()
                == 1)
    }

    @Test func concurrentRuntimesAndProcessCrashReleaseOwnership() async throws {
        let f = try RuntimeFixture()
        defer { f.clean() }
        let first = try await f.activate()
        let second = try f.open()
        _ = try CaptureService(store: first.store).ingest(CaptureRequest(text: "App capture"))
        _ = try CaptureService(store: second.store).ingest(CaptureRequest(text: "CLI capture"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import fcntl,sys; f=open(sys.argv[1],'a'); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.read()",
            f.paths.root.appendingPathComponent("sync-runtime.lock").path,
        ]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        #expect(try output.fileHandleForReading.read(upToCount: 6) == Data("ready\n".utf8))
        #expect(await first.runtime!.sync().phase == .busy)
        #expect(try first.store.syncClient?.pendingOperations().count == 2)
        kill(process.processIdentifier, SIGKILL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!process.isRunning)
        async let a = first.runtime!.sync()
        async let b = second.runtime!.sync()
        _ = await [a, b]
        #expect(await second.runtime!.sync().phase == .idle)
        #expect(try f.server.baseline().captures.count == 2)
        #expect(try f.server.baseline().deviceSequences[f.device] == 2)
        #expect(try first.store.syncClient?.pendingOperations().isEmpty == true)
    }

    private func outbox(_ store: Store) async throws -> [Data] {
        try await store.reader.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
    }
}

private enum RuntimeTestError: Error { case injected }

private struct RuntimeFixture: Sendable {
    let root: URL
    let paths: StoragePaths
    let binding: SyncLibraryBinding
    let device: UUID
    let enrollment: SyncEnrollment
    let configuration: MacSyncConfiguration
    let credentials: MemorySyncCredentialStore
    let server: SyncServer
    let wire: RuntimeWire
    let token = "synthetic-mac-credential"

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/capd-runtime-\(UUID())")
        paths = StoragePaths(root: root.appendingPathComponent("mac"))
        binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        device = UUID()
        enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.invalid/v1/sync")!, binding: binding,
            deviceID: device)
        configuration = MacSyncConfiguration(enrollment: enrollment)
        credentials = MemorySyncCredentialStore()
        try credentials.save(token, for: enrollment)
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("blobs"), libraryID: binding.libraryID,
            serviceID: binding.serviceID)
        wire = RuntimeWire(
            binding: binding, deviceID: device,
            handler: SyncHTTPHandler(
                serviceID: binding.serviceID,
                authorizer: RuntimeAuthorizer(
                    token: token,
                    principal: SyncPrincipal(
                        serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: device
                    )), server: { [server] _ in server }))
    }
    func activate() async throws -> MacLibrarySession {
        try await MacLibrarySession.activate(
            paths: paths, configuration: configuration, credentials: credentials, transport: wire)
    }
    func open() throws -> MacLibrarySession {
        try MacLibrarySession.open(paths: paths, credentials: credentials, transport: wire)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct RuntimeAuthorizer: SyncAuthorizer {
    let token: String
    let principal: SyncPrincipal
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        bearerCredential == token ? principal : nil
    }
}

private actor RuntimeWire: AsyncSyncTransport {
    enum Fault { case none, offline, hold, lostApply, missingProcessing }
    nonisolated let binding: SyncLibraryBinding
    nonisolated let deviceID: UUID
    let handler: SyncHTTPHandler
    var fault: Fault = .none
    var requests = 0
    var applies = 0
    var applyBodies: [Data] = []
    init(binding: SyncLibraryBinding, deviceID: UUID, handler: SyncHTTPHandler) {
        self.binding = binding
        self.deviceID = deviceID
        self.handler = handler
    }
    func setFault(_ fault: Fault) {
        self.fault = fault
        requests = 0
    }
    func waitForRequest() async throws {
        while requests == 0 { try await Task.sleep(for: .milliseconds(10)) }
    }
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        requests += 1
        if fault == .offline { throw SyncError.transportDisconnected }
        if fault == .hold { try await Task.sleep(for: .seconds(30)) }
        let reply = handler.handle(request)
        let envelope = try JSONDecoder().decode(SyncHTTPEnvelope.self, from: request.body)
        if fault == .missingProcessing, case .baseline = envelope.action {
            let decoded = try JSONDecoder().decode(SyncHTTPReply.self, from: reply.body)
            return SyncHTTPResponse(
                status: reply.status, headers: reply.headers,
                body: try JSONEncoder().encode(
                    SyncHTTPReply(
                        version: decoded.version, principal: decoded.principal,
                        result: decoded.result,
                        metadataContractVersion: decoded.metadataContractVersion)))
        }
        if case .apply = envelope.action {
            applies += 1
            applyBodies.append(request.body)
            if fault == .lostApply {
                fault = .none
                throw SyncError.transportDisconnected
            }
        }
        return reply
    }
}

private actor RuntimeGauge {
    var runs = 0
    func run() { runs += 1 }
}
private struct RuntimeStep: ProcessingStep {
    let gauge: RuntimeGauge
    func applies(to capture: Capture) -> Bool { capture.kind == .link }
    func run(_ capture: Capture, context: ProcessingContext) async throws -> StepResult {
        await gauge.run()
        try await Task.sleep(for: .milliseconds(10))
        return StepResult(
            bodyExtraction: BodyExtractionResult(
                body: "Synthetic pangolin body", status: .ok, source: .fetch))
    }
}
private struct RuntimeTagger: Tagger {
    var tags = ["generated"]
    func availability() -> TaggerAvailability { .available }
    func assignTags(_ input: TaggingInput, taxonomy: [String], mayInventNew: Bool) async throws
        -> [String]
    { tags }
    func planTaxonomy(_ samples: [TaggingInput], existing: [String]) async throws -> [String] {
        existing
    }
    func reviseTaxonomy(_ usage: [TagUsage]) async throws -> TaxonomyRevision {
        TaxonomyRevision(keep: usage.map(\.tag), merges: [:])
    }
}
