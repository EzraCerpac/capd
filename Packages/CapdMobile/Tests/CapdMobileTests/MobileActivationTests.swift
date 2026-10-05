import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdMobile
@testable import CapdSync

private func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
}

private struct ActivationAuthorizer: SyncAuthorizer {
    let enrollment: SyncEnrollment
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        guard bearerCredential == "synthetic-activation-only" else { return nil }
        return SyncPrincipal(
            serviceID: enrollment.binding.serviceID,
            libraryID: enrollment.binding.libraryID, deviceID: enrollment.deviceID)
    }
}

private struct ActivationRemote: AsyncSyncTransport {
    let binding: SyncLibraryBinding
    let deviceID: UUID
    let handler: SyncHTTPHandler
    var omitProcessing = false
    init(_ server: SyncServer, _ enrollment: SyncEnrollment, omitProcessing: Bool = false) {
        binding = enrollment.binding
        deviceID = enrollment.deviceID
        handler = SyncHTTPHandler(
            serviceID: binding.serviceID,
            authorizer: ActivationAuthorizer(enrollment: enrollment), server: { _ in server })
        self.omitProcessing = omitProcessing
    }
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        let response = handler.handle(request)
        guard omitProcessing else { return response }
        let reply = try JSONDecoder().decode(SyncHTTPReply.self, from: response.body)
        return SyncHTTPResponse(
            status: response.status, headers: response.headers,
            body: try encoded(
                SyncHTTPReply(
                    version: reply.version, principal: reply.principal,
                    result: reply.result, metadataContractVersion: reply.metadataContractVersion)))
    }
}

private struct ActivationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-activation-\(UUID())"
    ).resolvingSymlinksInPath()
    let credentials = MemorySyncCredentialStore()
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let endpoint = URL(string: "https://sync.example.invalid/v1/sync")!
    var activation: MobileLibraryActivation { .init(root: root, credentials: credentials) }
    var originalURL: URL { root.appendingPathComponent("Library/captures.sqlite") }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func populated() throws -> MobileLibrarySession {
        let old = try MobileLibrarySession.open(root: root, role: .app, credentials: credentials)
        let server = try SyncServer(
            databaseURL: root.appendingPathComponent("original.sqlite"),
            blobDirectory: root.appendingPathComponent("original-blobs"))
        let capture = try CaptureInput.make(
            text: "Synthetic orchid source", note: "Accepted original", isLink: false)
        try old.store.save(capture)
        try old.store.push(to: server)
        try old.store.update(id: capture.id, note: "Exact offline phone note", tags: ["manual"])
        try old.store.save(CaptureInput.make(text: "Second offline phone capture", isLink: false))
        return old
    }
    func authority() throws -> SyncServer {
        try SyncServer(
            databaseURL: root.appendingPathComponent("new-authority.sqlite"),
            blobDirectory: root.appendingPathComponent("new-authority-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
    }
    func handoff(_ preparation: MobileLibraryPreparation, server: SyncServer) throws
        -> MobileReviewedImport
    {
        let preview = try server.previewContentSnapshotImport(preparation.snapshot)
        let receipt = try server.importContentSnapshot(preparation.snapshot, preview: preview)
        let review = MobileSnapshotReview(
            version: 1, authorityDirectory: "/synthetic/authority",
            snapshotSHA256: preparation.manifestFileDigest, assets: [], preview: preview)
        let r = try encoded(review)
        let c = try encoded(receipt)
        return try MobileReviewedImport(
            reviewBytes: r, receiptBytes: c,
            approvedReviewSHA256: BlobReference(data: r).digest,
            approvedReceiptSHA256: BlobReference(data: c).digest)
    }
    func originalFiles() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for suffix in ["", "-wal"] {
            let url = URL(fileURLWithPath: originalURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                result[suffix] = try Data(contentsOf: url)
            }
        }
        return result
    }
}

@Test func boundStoreInitializerCannotMutateOrMarkAnExistingUnboundLibrary() throws {
    let f = ActivationFixture()
    defer { f.clean() }
    let old = try f.populated()
    let pending = try old.store.pending()
    let bytes = try f.originalFiles()
    #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
        try MobileStore(url: f.originalURL, deviceID: UUID(), binding: f.binding)
    }
    #expect(try old.store.pending() == pending)
    #expect(try f.originalFiles() == bytes)
    #expect(
        !FileManager.default.fileExists(
            atPath: f.root.appendingPathComponent("Library/assets/library-owner").path))
}

@Test func explicitArchiveOnlySelectionRetainsOldOutboxAndLoadsOnlyAuthorityContent() async throws {
    let f = ActivationFixture()
    defer { f.clean() }
    let old = try f.populated()
    let pending = try old.store.pending()
    let originalBytes = try f.originalFiles()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let server = try f.authority()
    let authorityCapture = SharedCapture(
        source: CaptureSource(
            kind: .text, contentHash: BlobReference(data: Data("Synthetic authority".utf8)).digest,
            selection: "Synthetic existing authority source"))
    _ = try server.apply(
        SyncOperation(
            deviceID: UUID(), sequence: 1, captureID: authorityCapture.id,
            baseRevision: 0, mutation: .create(authorityCapture)))
    await #expect(throws: MobileActivationError.missingImport) {
        try await f.activation.activate(
            prep, handoff: nil, credential: "synthetic-activation-only",
            transport: ActivationRemote(server, prep.enrollment))
    }
    let config = try await f.activation.activate(
        prep, handoff: nil, credential: "synthetic-activation-only",
        originalDisposition: .keepArchivedOnly,
        transport: ActivationRemote(server, prep.enrollment))
    #expect(config.enrollment?.deviceID != old.store.deviceID)
    #expect(try f.originalFiles() == originalBytes)
    let retained = try MobileStore(url: f.originalURL)
    let archive = try MobileStore(
        url: prep.directory(in: f.root).appendingPathComponent("Original/captures.sqlite"))
    #expect(try retained.pending() == pending)
    #expect(try archive.pending() == pending)
    let app = try MobileLibrarySession.open(root: f.root, role: .app, credentials: f.credentials)
    let share = try MobileLibrarySession.open(root: f.root, role: .shareExtension)
    #expect(try app.store.search().map(\.id) == [authorityCapture.id])
    #expect(try share.store.search().map(\.id) == [authorityCapture.id])
    #expect(try app.store.pending().isEmpty)
    #expect(try server.baseline().captures.map(\.id) == [authorityCapture.id])
    #expect(try server.baseline().deviceSequences[prep.enrollment.deviceID] == nil)
    _ = try share.save(CaptureInput.make(text: "Fresh bound share", isLink: false))
    #expect(try app.store.pending().map(\.sequence) == [1])
}

@Test func populatedActivationPreservesOldHistoryAndAppShareUseFreshBoundStore() async throws {
    let f = ActivationFixture()
    defer { f.clean() }
    let oldApp = try f.populated()
    let oldShare = try MobileLibrarySession.open(root: f.root, role: .shareExtension)
    let pending = try oldApp.store.pending()
    #expect(pending.map(\.sequence) == [2, 3])
    let captures = try oldApp.store.search()
    let bytes = try f.originalFiles()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    #expect(try f.originalFiles() == bytes)
    for (suffix, expected) in bytes {
        #expect(
            try Data(
                contentsOf: prep.directory(in: f.root)
                    .appendingPathComponent("OriginalRaw/captures.sqlite" + suffix)) == expected)
    }
    #expect(try f.activation.preparations() == [prep])
    let archive = try MobileStore(
        url: prep.directory(in: f.root).appendingPathComponent("Original/captures.sqlite"))
    #expect(try archive.pending() == pending)
    #expect(try archive.search() == captures)
    let server = try f.authority()
    let handoff = try f.handoff(prep, server: server)
    let config = try await f.activation.activate(
        prep, handoff: handoff,
        credential: "synthetic-activation-only",
        transport: ActivationRemote(server, prep.enrollment))
    #expect(config.enrollment?.deviceID != oldApp.store.deviceID)
    #expect(try server.baseline().deviceSequences.isEmpty)
    #expect(try f.originalFiles() == bytes)
    #expect(!oldShare.isCurrent(oldShare.token))
    #expect(throws: MobileActivationError.sessionReplaced) {
        try oldShare.save(CaptureInput.make(text: "Stale share draft", isLink: false))
    }
    let app = try MobileLibrarySession.open(root: f.root, role: .app, credentials: f.credentials)
    let share = try MobileLibrarySession.open(
        root: f.root, role: .shareExtension, credentials: FailingCredentials())
    #expect(app.token == share.token)
    #expect(app.store.deviceID == prep.enrollment.deviceID)
    #expect(app.store.libraryBinding == f.binding)
    #expect(await share.adapter.availability() == .unconfigured)
    #expect(await app.adapter.availability() == .ready)
    #expect(try app.store.search().count == captures.count)
    #expect(try app.store.pending().isEmpty)
    let saved = try share.save(CaptureInput.make(text: "Shared after cutover", isLink: false))
    #expect(saved.libraryID == f.binding.libraryID && saved.sessionToken == app.token)
    #expect(try app.store.capture(id: saved.capture.id) != nil)
    #expect(try app.store.pending().map(\.sequence) == [1])
    let coordinator = MobileSyncCoordinator(
        store: app.store,
        adapter: ActivationAdapter(remote: ActivationRemote(server, prep.enrollment)))
    _ = try await coordinator.sync()
    #expect(try app.store.pending().isEmpty)
    #expect(try server.baseline().deviceSequences[prep.enrollment.deviceID] == 1)
    #expect(try archive.pending() == pending)  // Administrative receipts never ACK the old outbox.
}

@Test func stalePreparationMissingImportAndBadHashesRefuseWithoutCredentialsOrSelector()
    async throws
{
    let f = ActivationFixture()
    defer { f.clean() }
    let old = try f.populated()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let server = try f.authority()
    let handoff = try f.handoff(prep, server: server)
    await #expect(throws: MobileActivationError.missingImport) {
        try await f.activation.activate(
            prep, handoff: nil, credential: "synthetic-activation-only",
            transport: ActivationRemote(server, prep.enrollment))
    }
    #expect(throws: MobileActivationError.invalidHandoff) {
        try MobileReviewedImport(
            reviewBytes: encoded(handoff.review), receiptBytes: encoded(handoff.receipt),
            approvedReviewSHA256: String(repeating: "0", count: 64),
            approvedReceiptSHA256: String(repeating: "0", count: 64))
    }
    try old.store.save(CaptureInput.make(text: "Changed after review", isLink: false))
    let pending = try old.store.pending()
    await #expect(throws: MobileActivationError.stalePreparation) {
        try await f.activation.activate(
            prep, handoff: handoff, credential: "synthetic-activation-only",
            transport: ActivationRemote(server, prep.enrollment))
    }
    #expect(try old.store.pending() == pending)
    #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
    #expect(throws: SyncConnectionError.credentialUnavailable) {
        try f.credentials.read(for: prep.enrollment)
    }
}

@Test func publicationFailureRollsBackWhileShareIsFencedAndRetainsBothLibraries() async throws {
    let f = ActivationFixture()
    defer { f.clean() }
    let old = try f.populated()
    let pending = try old.store.pending()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let server = try f.authority()
    let handoff = try f.handoff(prep, server: server)
    await #expect(throws: SyncHTTPError.unavailable) {
        try await f.activation.activate(
            prep, handoff: handoff, credential: "synthetic-activation-only",
            transport: ActivationRemote(server, prep.enrollment),
            afterPublication: {
                #expect(throws: MobileActivationError.transitionBusy) {
                    try MobileLibrarySession.open(root: f.root, role: .shareExtension)
                }
                throw SyncHTTPError.unavailable
            })
    }
    #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
    #expect(try old.store.pending() == pending)
    #expect(try old.store.search().count == 2)
    #expect(throws: SyncConnectionError.credentialUnavailable) {
        try f.credentials.read(for: prep.enrollment)
    }
    #expect(
        try FileManager.default.contentsOfDirectory(
            atPath: f.root.appendingPathComponent("ConnectedLibraries").path
        ).count == 1)
    let recovered = try await f.activation.activate(
        prep, handoff: handoff,
        credential: "synthetic-activation-only",
        transport: ActivationRemote(server, prep.enrollment))
    #expect(recovered.enrollment == prep.enrollment)
    #expect(
        try server.retainedContentSnapshotImport(prep.snapshot.snapshotID)?.receipt
            == handoff.receipt)
}

@Test func capabilityAndCredentialFailuresPreserveOriginalAndFreshIdentityMustHaveNoHistory()
    async throws
{
    let f = ActivationFixture()
    defer { f.clean() }
    let old = try f.populated()
    let pending = try old.store.pending()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let server = try f.authority()
    let handoff = try f.handoff(prep, server: server)
    await #expect(throws: SyncHTTPError.unsupportedVersion) {
        try await f.activation.activate(
            prep, handoff: handoff, credential: "synthetic-activation-only",
            transport: ActivationRemote(server, prep.enrollment, omitProcessing: true))
    }
    let failure = MobileLibraryActivation(root: f.root, credentials: FailingCredentials())
    await #expect(throws: SyncConnectionError.credentialUnavailable) {
        try await failure.activate(
            prep, handoff: handoff, credential: "synthetic-activation-only",
            transport: ActivationRemote(server, prep.enrollment))
    }
    let record = SharedCapture(
        source: CaptureSource(kind: .text, selection: "Already used fresh identity"))
    _ = try server.apply(
        SyncOperation(
            deviceID: prep.enrollment.deviceID, sequence: 1,
            captureID: record.id, baseRevision: 0, mutation: .create(record)))
    await #expect(throws: MobileActivationError.identityAlreadyUsed) {
        try await f.activation.activate(
            prep, handoff: handoff, credential: "synthetic-activation-only",
            transport: ActivationRemote(server, prep.enrollment))
    }
    #expect(try old.store.pending() == pending)
    #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
}

@Test func pinnedReceiptCannotActivateAnAuthorityThatLacksTheImportedContent() async throws {
    let f = ActivationFixture()
    defer { f.clean() }
    let old = try f.populated()
    let pending = try old.store.pending()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let imported = try f.authority()
    let handoff = try f.handoff(prep, server: imported)
    let wrong = try SyncServer(
        databaseURL: f.root.appendingPathComponent("unimported.sqlite"),
        blobDirectory: f.root.appendingPathComponent("unimported-blobs"),
        libraryID: f.binding.libraryID, serviceID: f.binding.serviceID)
    await #expect(throws: MobileActivationError.missingImport) {
        try await f.activation.activate(
            prep, handoff: handoff, credential: "synthetic-activation-only",
            transport: ActivationRemote(wrong, prep.enrollment))
    }
    #expect(try old.store.pending() == pending)
    #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
    // A hash-pinned but altered source/canonical mapping is still rejected.
    var json = try #require(
        JSONSerialization.jsonObject(with: encoded(handoff.receipt)) as? [String: Any])
    var items = try #require(json["items"] as? [[String: Any]])
    items[0]["canonicalCaptureID"] = UUID().uuidString
    json["items"] = items
    let altered = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
    let review = try encoded(handoff.review)
    let invalid = try MobileReviewedImport(
        reviewBytes: review, receiptBytes: altered,
        approvedReviewSHA256: BlobReference(data: review).digest,
        approvedReceiptSHA256: BlobReference(data: altered).digest)
    #expect(throws: MobileActivationError.invalidHandoff) {
        try f.activation.validate(invalid, for: prep)
    }
}

@Test func snapshotCopiesRequiredSyntheticImageAssetsAndPreservesGeneratedMetadata() throws {
    let f = ActivationFixture()
    defer { f.clean() }
    let app = try MobileLibrarySession.open(root: f.root, role: .app, credentials: f.credentials)
    let old = try SyncServer(
        databaseURL: f.root.appendingPathComponent("old-image.sqlite"),
        blobDirectory: f.root.appendingPathComponent("old-image-blobs"))
    let image = Data("synthetic image bytes; no photo library".utf8)
    let blob = BlobReference(data: image)
    try old.upload(blob, offset: 0, chunk: image, final: true)
    var record = SharedCapture(
        source: CaptureSource(
            kind: .image,
            contentHash: blob.digest, title: "Synthetic image", blob: blob),
        metadata: CaptureMetadata(sourceAppBundleID: "synthetic.image.fixture"))
    record.generated = GeneratedContent(body: "Kept body", ocrText: "Kept OCR", tags: ["generated"])
    _ = try old.apply(
        SyncOperation(
            deviceID: UUID(), sequence: 1, captureID: record.id,
            baseRevision: 0, mutation: .create(record)))
    try app.store.pull(from: old)
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    #expect(prep.snapshot.captures.first?.metadata == record.metadata)
    #expect(prep.snapshot.captures.first?.generated == record.generated)
    #expect(
        try Data(
            contentsOf: prep.transferDirectory(in: f.root).appendingPathComponent(
                "assets/\(blob.digest)")) == image)
    #expect(
        try Data(
            contentsOf: prep.directory(in: f.root).appendingPathComponent(
                "Original/assets/\(blob.digest)")) == image)
    #expect(try app.store.search().first?.body == "Kept body")
}

@Test
func emptyLibraryConnectsWithoutInventingSnapshotImportAndAliasesReturnCanonicalSavedProjection()
    async throws
{
    let f = ActivationFixture()
    defer { f.clean() }
    _ = try MobileLibrarySession.open(root: f.root, role: .app, credentials: f.credentials)
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    #expect(prep.captureCount == 0)
    let server = try f.authority()
    _ = try await f.activation.activate(
        prep, handoff: nil, credential: "synthetic-activation-only",
        transport: ActivationRemote(server, prep.enrollment))
    let app = try MobileLibrarySession.open(root: f.root, role: .app, credentials: f.credentials)
    let first = try app.save(CaptureInput.make(text: "Same canonical source", isLink: false))
    let second = try app.save(CaptureInput.make(text: "Same canonical source", isLink: false))
    #expect(first.capture.id == second.capture.id)
    #expect(second.capture.seenCount == 2)
    #expect(second.sessionToken == app.token)
    #expect(try app.store.pending().count == 2)
}

@Test func atomicCredentialCreationPreservesDifferentExistingValueAndInterruptedIdenticalAttempt()
    async throws
{
    let f = ActivationFixture()
    defer { f.clean() }
    _ = try f.populated()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let server = try f.authority()
    let handoff = try f.handoff(prep, server: server)
    try f.credentials.save("other-existing-synthetic-credential", for: prep.enrollment)
    await #expect(throws: SyncConnectionError.invalidCredential) {
        try await f.activation.activate(
            prep, handoff: handoff, credential: "synthetic-activation-only",
            transport: ActivationRemote(server, prep.enrollment))
    }
    #expect(try f.credentials.read(for: prep.enrollment) == "other-existing-synthetic-credential")
    #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
    try f.credentials.remove(for: prep.enrollment)
    #expect(try f.credentials.insertIfAbsent("synthetic-activation-only", for: prep.enrollment))
    await #expect(throws: SyncHTTPError.unavailable) {
        try await f.activation.activate(
            prep, handoff: handoff, credential: "synthetic-activation-only",
            transport: ActivationRemote(server, prep.enrollment),
            afterPublication: { throw SyncHTTPError.unavailable })
    }
    // Rollback owns only newly created credentials; it must retain a prior identical attempt.
    #expect(try f.credentials.read(for: prep.enrollment) == "synthetic-activation-only")
    _ = try await f.activation.activate(
        prep, handoff: handoff, credential: "synthetic-activation-only",
        transport: ActivationRemote(server, prep.enrollment))
}

@Test func transitionAndSearchLeasesExcludeCompetingProcessesAndSelectorCannotFollowSymlink()
    async throws
{
    let f = ActivationFixture()
    defer { f.clean() }
    let app = try f.populated()
    let exclusive = try MobileLibraryLease(root: f.root, exclusive: true)
    #expect(throws: MobileActivationError.transitionBusy) { try app.store.search() }
    #expect(throws: MobileActivationError.transitionBusy) {
        try MobileLibrarySession.open(root: f.root, role: .shareExtension)
    }
    withExtendedLifetime(exclusive) {}
    // Explicit lexical scope keeps the transition lock out of the search lease test below.
}

@Test func systemSearchLeaseHoldsGenerationAndSerializesMainAndExtensionDeletion() async throws {
    let f = ActivationFixture()
    defer { f.clean() }
    let app = try f.populated()
    let share = try MobileLibrarySession.open(root: f.root, role: .shareExtension)
    try await app.withSystemSearchLease {
        await #expect(throws: MobileActivationError.transitionBusy) {
            try await share.withSystemSearchLease { true }
        }
        #expect(throws: MobileActivationError.transitionBusy) {
            try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
        }
    }
    try await share.withSystemSearchLease { #expect(share.isCurrent(share.token)) }
    let selector = f.root.appendingPathComponent("active-library.json")
    let external = f.root.appendingPathComponent("fake-selector.json")
    try encoded(MobileLibraryConfiguration.legacy).write(to: external)
    try FileManager.default.createSymbolicLink(at: selector, withDestinationURL: external)
    #expect(throws: MobileActivationError.invalidConfiguration) {
        try MobileLibraryAccess.selected(in: f.root)
    }
}

private struct FailingCredentials: SyncCredentialStore {
    func read(for enrollment: SyncEnrollment) throws -> String {
        throw SyncConnectionError.credentialUnavailable
    }
    func save(_ credential: String, for enrollment: SyncEnrollment) throws {
        throw SyncConnectionError.credentialUnavailable
    }
    func remove(for enrollment: SyncEnrollment) throws {}
}

private struct ActivationAdapter: MobileSyncAdapter {
    let remote: any AsyncSyncTransport
    func availability() async -> SyncAvailability { .ready }
    func transport() async -> (any SyncTransport)? { nil }
    func asyncConnection() async -> MobileAsyncSyncConnection? {
        .init(transport: remote, credential: { "synthetic-activation-only" })
    }
}

private actor DrainRemote: AsyncSyncTransport {
    nonisolated let binding: SyncLibraryBinding
    nonisolated let deviceID: UUID
    let base: ActivationRemote
    var entered = false
    var waiting: CheckedContinuation<Void, Never>?
    init(_ base: ActivationRemote) {
        self.base = base
        binding = base.binding
        deviceID = base.deviceID
    }
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        entered = true
        // Intentionally ignores cancellation until transport drains.
        await withCheckedContinuation { waiting = $0 }
        try Task.checkCancellation()
        return try await base.send(request)
    }
    func release() {
        waiting?.resume()
        waiting = nil
    }
}
private actor DrainFlag {
    var done = false
    func finish() { done = true }
}

@Test func schedulerDrainWaitsForCancelledTransportAndConcurrentForegroundCannotRestartIt()
    async throws
{
    let f = ActivationFixture()
    defer { f.clean() }
    let store = try MobileStore(url: f.originalURL, deviceID: UUID(), binding: f.binding)
    let enrollment = try SyncEnrollment(
        endpoint: f.endpoint, binding: f.binding, deviceID: store.deviceID)
    let remote = DrainRemote(ActivationRemote(try f.authority(), enrollment))
    let controller = AutomaticSyncController(
        store: store, adapter: ActivationAdapter(remote: remote))
    await controller.foreground()
    for _ in 0..<200 {
        if await remote.entered { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await remote.entered)
    let flag = DrainFlag()
    let drain = Task {
        await controller.suspendAndDrain()
        await flag.finish()
    }
    for _ in 0..<200 {
        if await controller.currentState().phase == .paused { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    await controller.foreground()
    await controller.retryNow()
    #expect(!(await flag.done))
    await remote.release()
    await drain.value
    #expect(await flag.done)
    #expect(await controller.currentState().phase == .paused)
}

private actor ActivationBudgetRemote: AsyncSyncTransport {
    nonisolated let binding: SyncLibraryBinding
    nonisolated let deviceID: UUID
    let base: ActivationRemote
    let captures: [SharedCapture]
    let targetCursor: Int64
    let verifiedCursor: Int64
    let remoteDeviceID = UUID()
    var baselineReads = 0
    var pageReads = 0

    init(
        server: SyncServer, enrollment: SyncEnrollment, targetCursor: Int64,
        verifiedCursor: Int64? = nil
    ) throws {
        base = ActivationRemote(server, enrollment)
        binding = enrollment.binding
        deviceID = enrollment.deviceID
        captures = try server.baseline().captures
        self.targetCursor = targetCursor
        self.verifiedCursor = verifiedCursor ?? targetCursor
    }

    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        let envelope = try JSONDecoder().decode(SyncHTTPEnvelope.self, from: request.body)
        let result: SyncHTTPResult
        switch envelope.action {
        case .changes(let cursor, let limit):
            pageReads += 1
            guard pageReads <= MobileStore.pullPageBudget else {
                throw SyncHTTPError.unavailable
            }
            let count = Int(min(Int64(limit), targetCursor - cursor))
            let changes = (0..<count).map { offset in
                let revision = cursor + Int64(offset) + 1
                var capture = captures[offset % captures.count]
                capture.revision = revision
                return FeedChange(
                    cursor: revision, operationID: UUID(), deviceID: remoteDeviceID,
                    sequence: revision, requestedCaptureID: capture.id, capture: capture)
            }
            result = .page(FeedPage(cursor: cursor + Int64(count), changes: changes))
        case .baselinePage(let after, let limit, _):
            if after == nil { baselineReads += 1 }
            let records = captures.sorted { $0.id.uuidString < $1.id.uuidString }
                .filter { after == nil || $0.id.uuidString > after!.uuidString }
            result = .baseline(
                Baseline(
                    cursor: baselineReads == 1 ? targetCursor : verifiedCursor,
                    captures: Array(records.prefix(limit)), deviceSequences: [:],
                    totalCaptureCount: captures.count))
        default:
            return try await base.send(request)
        }
        return SyncHTTPResponse(
            status: 200, headers: ["Content-Type": "application/json"],
            body: try encoded(
                SyncHTTPReply(
                    version: 1,
                    principal: SyncPrincipal(
                        serviceID: binding.serviceID, libraryID: binding.libraryID,
                        deviceID: deviceID),
                    result: result, metadataContractVersion: 1,
                    generatedProcessingContractVersion: 1, extractionQualityContractVersion: 1)))
    }
}

@Test(arguments: [false, true])
func incompleteActivationRefusesEmptyAndArchiveOnlyOriginals(archiveOnly: Bool) async throws {
    let f = ActivationFixture()
    defer { f.clean() }
    let old =
        try archiveOnly
        ? f.populated()
        : MobileLibrarySession.open(root: f.root, role: .app, credentials: f.credentials)
    let pending = try old.store.pending()
    let bytes = try f.originalFiles()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let server = try f.authority()
    let capture = SharedCapture(
        source: CaptureSource(kind: .text, selection: "Synthetic authority feed budget"))
    _ = try server.apply(
        SyncOperation(
            deviceID: UUID(), sequence: 1, captureID: capture.id,
            baseRevision: 0, mutation: .create(capture)))
    let remote = try ActivationBudgetRemote(
        server: server, enrollment: prep.enrollment, targetCursor: 10_001)
    await #expect(throws: SyncError.invalidCursor) {
        try await f.activation.activate(
            prep, handoff: nil, credential: "synthetic-activation-only",
            originalDisposition: archiveOnly ? .keepArchivedOnly : .importReviewed,
            transport: remote)
    }
    #expect(await remote.pageReads == MobileStore.pullPageBudget)
    #expect(await remote.baselineReads == 2)
    #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
    #expect(try old.store.pending() == pending)
    #expect(try f.originalFiles() == bytes)
    #expect(throws: SyncConnectionError.credentialUnavailable) {
        try f.credentials.read(for: prep.enrollment)
    }
}

@Test(arguments: [false, true])
func reviewedCanonicalRecordsOnEarlyPagesCannotBypassVerifiedCursor(lateAuthority: Bool)
    async throws
{
    let f = ActivationFixture()
    defer { f.clean() }
    let old = try f.populated()
    let pending = try old.store.pending()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let server = try f.authority()
    let handoff = try f.handoff(prep, server: server)
    let target: Int64 = lateAuthority ? 100 : 10_001
    let remote = try ActivationBudgetRemote(
        server: server, enrollment: prep.enrollment, targetCursor: target,
        verifiedCursor: lateAuthority ? target + 1 : target)
    await #expect(throws: SyncError.invalidCursor) {
        try await f.activation.activate(
            prep, handoff: handoff, credential: "synthetic-activation-only", transport: remote)
    }
    #expect(await remote.baselineReads == 2)
    let stages = try FileManager.default.contentsOfDirectory(
        at: f.root.appendingPathComponent("ConnectedLibraries"), includingPropertiesForKeys: nil)
    let stage = try MobileStore(
        url: #require(stages.first).appendingPathComponent("captures.sqlite"),
        deviceID: prep.enrollment.deviceID, binding: prep.enrollment.binding)
    #expect(
        Set(try stage.search().map(\.id)) == Set(handoff.receipt.items.map(\.canonicalCaptureID)))
    #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
    #expect(try old.store.pending() == pending)
    #expect(throws: SyncConnectionError.credentialUnavailable) {
        try f.credentials.read(for: prep.enrollment)
    }
}

@Test func activationPublishesWhenBoundedPullReachesVerifiedCursorExactly() async throws {
    let f = ActivationFixture()
    defer { f.clean() }
    _ = try f.populated()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let server = try f.authority()
    let handoff = try f.handoff(prep, server: server)
    let remote = try ActivationBudgetRemote(
        server: server, enrollment: prep.enrollment, targetCursor: 10_000)
    let config = try await f.activation.activate(
        prep, handoff: handoff, credential: "synthetic-activation-only", transport: remote)
    #expect(await remote.pageReads == MobileStore.pullPageBudget)
    #expect(try MobileLibraryAccess.selected(in: f.root) == config)
    let reader = try DatabaseQueue(path: config.databaseURL(in: f.root).path)
    #expect(
        try await reader.read { try Int64.fetchOne($0, sql: "SELECT cursor FROM sync_meta") }
            == 10_000)
}

private actor ActivationPreflightRemote: AsyncSyncTransport {
    enum Failure: Error { case unexpectedFullBaseline }
    nonisolated let binding: SyncLibraryBinding
    nonisolated let deviceID: UUID
    let base: ActivationRemote
    let requiresSummary: Bool
    var baselineLimits: [Int] = []

    init(server: SyncServer, enrollment: SyncEnrollment, requiresSummary: Bool) {
        base = ActivationRemote(server, enrollment)
        binding = enrollment.binding
        deviceID = enrollment.deviceID
        self.requiresSummary = requiresSummary
    }

    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        let envelope = try JSONDecoder().decode(SyncHTTPEnvelope.self, from: request.body)
        if case .baselinePage(_, let limit, _) = envelope.action {
            baselineLimits.append(limit)
            if requiresSummary && limit != 0 { throw Failure.unexpectedFullBaseline }
        }
        return try await base.send(request)
    }
}

@Test(arguments: [false, true])
func activationWithoutReviewedImportUsesSummaryPreflights(archiveOriginal: Bool) async throws {
    let f = ActivationFixture()
    defer { f.clean() }
    if archiveOriginal {
        _ = try f.populated()
    } else {
        _ = try MobileLibrarySession.open(root: f.root, role: .app, credentials: f.credentials)
    }
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let server = try f.authority()
    let capture = SharedCapture(
        source: CaptureSource(kind: .text, selection: "Synthetic summary preflight capture"))
    _ = try server.apply(
        SyncOperation(
            deviceID: UUID(), sequence: 1, captureID: capture.id,
            baseRevision: 0, mutation: .create(capture)))
    let remote = ActivationPreflightRemote(
        server: server, enrollment: prep.enrollment, requiresSummary: true)
    let config = try await f.activation.activate(
        prep, handoff: nil, credential: "synthetic-activation-only",
        originalDisposition: archiveOriginal ? .keepArchivedOnly : .importReviewed,
        transport: remote)
    #expect(await remote.baselineLimits == [0, 0])
    #expect(try MobileLibraryAccess.selected(in: f.root) == config)
    let app = try MobileLibrarySession.open(root: f.root, role: .app, credentials: f.credentials)
    #expect(try app.store.search().map(\.id) == [capture.id])
    #expect(try app.store.pending().isEmpty)
}

@Test func reviewedActivationStillChecksFullAuthorityContentBeforePublication() async throws {
    let f = ActivationFixture()
    defer { f.clean() }
    _ = try f.populated()
    let prep = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    let server = try f.authority()
    let handoff = try f.handoff(prep, server: server)
    let remote = ActivationPreflightRemote(
        server: server, enrollment: prep.enrollment, requiresSummary: false)
    _ = try await f.activation.activate(
        prep, handoff: handoff, credential: "synthetic-activation-only", transport: remote)
    let limits = await remote.baselineLimits
    #expect(limits.count >= 2)
    #expect(limits.first == 100)
    #expect(limits.last == 100)
}
