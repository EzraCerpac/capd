import Foundation
import GRDB
import Network
import Testing

@testable import CapdSync

@Suite("Synthetic URLSession sync")
struct AsyncHTTPTests {
    @Test func activationBaselineRequiresBothCapabilitiesBeforeCommittingLocalState() async throws {
        for mode in [
            CapabilityAuthority.Mode.processingAbsent, .processingMalformed,
            .processingWrongVersion, .absent, .wrongPrincipal,
        ] {
            let fixture = try AsyncHTTPFixture()
            defer { fixture.clean() }
            let authority = CapabilityAuthority(handler: fixture.handler, mode: mode)
            let host = try await SyntheticHTTPHost.start(
                handler: fixture.handler, execute: { authority.handle($0) })
            defer { host.stop() }
            let transport = try fixture.transport(host)
            let localState = try DatabaseQueue(
                path: fixture.root.appendingPathComponent("activation.sqlite").path)
            try await localState.write {
                try $0.execute(sql: "CREATE TABLE activation (libraryID TEXT, serviceID TEXT)")
            }
            let expected: SyncHTTPError =
                mode == .processingMalformed || mode == .wrongPrincipal
                ? .invalidResponse : .unsupportedVersion
            await #expect(throws: expected) {
                _ = try await transport.importBaseline(
                    credential: { fixture.token }, requiringGeneratedProcessingContract: true)
                try await localState.write {
                    try $0.execute(
                        sql: "INSERT INTO activation VALUES (?, ?)",
                        arguments: [
                            fixture.binding.libraryID.uuidString,
                            fixture.binding.serviceID.uuidString,
                        ])
                }
            }
            #expect(
                try await localState.read {
                    try Int.fetchOne($0, sql: "SELECT count(*) FROM activation")
                }
                    == 0)
            #expect(host.applyBodies.isEmpty)
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.root.appendingPathComponent("client.sqlite").path))
            if mode == .processingAbsent || mode == .processingWrongVersion {
                let baseline = try await transport.importBaseline(credential: { fixture.token })
                #expect(baseline == (try fixture.server.baseline()))
            }
            authority.mode = .current
            let baseline = try await transport.importBaseline(
                credential: { fixture.token }, requiringGeneratedProcessingContract: true)
            #expect(baseline == (try fixture.server.baseline()))
            try await localState.write {
                try $0.execute(
                    sql: "INSERT INTO activation VALUES (?, ?)",
                    arguments: [
                        fixture.binding.libraryID.uuidString,
                        fixture.binding.serviceID.uuidString,
                    ])
            }
            let identity = try await localState.read {
                let row = try #require(try Row.fetchOne($0, sql: "SELECT * FROM activation"))
                return [row["libraryID"] as String, row["serviceID"] as String]
            }
            #expect(
                identity == [
                    fixture.binding.libraryID.uuidString, fixture.binding.serviceID.uuidString,
                ])
        }
    }

    @Test func processingCapabilityFailuresAndDowngradeRetainExactQueueWithoutServerWrites()
        async throws
    {
        for mode in [
            CapabilityAuthority.Mode.processingAbsent, .processingMalformed,
            .processingWrongVersion, .processingDowngrade,
        ] {
            let fixture = try AsyncHTTPFixture()
            defer { fixture.clean() }
            var capture = SharedCapture(
                source: CaptureSource(kind: .text, selection: "Processing capability fixture"))
            capture.generated = GeneratedContent(
                body: "Kept body", ocrText: "Kept OCR", tags: ["kept tag"])
            try fixture.server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: capture.id, baseRevision: 0,
                    mutation: .create(capture)))
            let authority = CapabilityAuthority(handler: fixture.handler, mode: .current)
            let host = try await SyntheticHTTPHost.start(
                handler: fixture.handler, execute: { authority.handle($0) })
            defer { host.stop() }
            let transport = try fixture.transport(host)
            let client = try fixture.client()
            try await client.pull(from: transport, credential: { fixture.token })
            let operation = try client.enqueue(
                captureID: capture.id,
                mutation: .edit(
                    CaptureEdit(
                        generatedPatch: GeneratedContentPatch(
                            taggingProcessing: .processed(inputFingerprint: "exact-fingerprint")))))
            let before = try fixture.server.baseline().captures
            let bytes = try fixture.pendingBytes()
            authority.mode = mode
            let expected: SyncHTTPError =
                mode == .processingMalformed ? .invalidResponse : .unsupportedVersion
            await #expect(throws: expected) {
                try await client.push(to: transport, credential: { fixture.token })
            }
            #expect(try fixture.server.baseline().captures == before)
            #expect(host.applyBodies.count == (mode == .processingDowngrade ? 1 : 0))
            let reopened = try fixture.client()
            #expect(try reopened.pendingOperations() == [operation])
            #expect(try fixture.pendingBytes() == bytes)
            authority.mode = .current
            try await reopened.push(to: transport, credential: { fixture.token })
            #expect(try reopened.pendingOperations().isEmpty)
            let generated = try #require(try fixture.server.baseline().captures.first?.generated)
            #expect(generated.body == capture.generated.body)
            #expect(generated.ocrText == capture.generated.ocrText)
            #expect(generated.tags == capture.generated.tags)
            #expect(generated.taggingProcessed == true)
            #expect(generated.taggingInputFingerprint == "exact-fingerprint")
            #expect(
                try SyncDatabase.decode(SyncHTTPEnvelope.self, host.applyBodies.last!).version == 3)
        }
    }

    @Test func staleProcessingMarkerLostResponseRetriesExactBytesAndKeepsNewerGeneratedFields()
        async throws
    {
        let fixture = try AsyncHTTPFixture()
        defer { fixture.clean() }
        let seedDevice = UUID()
        var capture = SharedCapture(
            source: CaptureSource(kind: .text, selection: "Stale completed input"))
        capture.generated = GeneratedContent(
            body: "Old body", ocrText: "Old OCR", tags: ["old tag"])
        try fixture.server.apply(
            SyncOperation(
                deviceID: seedDevice, sequence: 1, captureID: capture.id, baseRevision: 0,
                mutation: .create(capture)))
        let host = try await SyntheticHTTPHost.start(handler: fixture.handler)
        defer { host.stop() }
        let transport = try fixture.transport(host)
        let client = try fixture.client()
        try await client.pull(from: transport, credential: { fixture.token })
        let operation = try client.enqueue(
            captureID: capture.id,
            mutation: .edit(
                CaptureEdit(
                    generatedPatch: GeneratedContentPatch(
                        taggingProcessing: .processed(inputFingerprint: "exact-old-input")))))
        let queuedBytes = try fixture.pendingBytes()
        try fixture.server.apply(
            SyncOperation(
                deviceID: seedDevice, sequence: 2, captureID: capture.id, baseRevision: 1,
                mutation: .edit(
                    CaptureEdit(
                        generatedPatch: GeneratedContentPatch(
                            body: .set("Newer body"), ocrText: .set("Newer OCR"),
                            tags: ["newer tag"])))))
        host.fault = .dropApply
        await #expect(throws: SyncError.transportDisconnected) {
            try await client.push(to: transport, credential: { fixture.token })
        }
        #expect(try fixture.pendingBytes() == queuedBytes)
        let reopened = try fixture.client()
        #expect(try reopened.pendingOperations() == [operation])
        let receipt = try #require(
            try await reopened.push(to: transport, credential: { fixture.token }).first)
        #expect(receipt.operationID == operation.id)
        #expect(host.applyBodies.count == 2)
        #expect(host.applyBodies.first == host.applyBodies.last)
        #expect(
            try SyncDatabase.decode(SyncHTTPEnvelope.self, host.applyBodies.first!).version == 3)
        let generated = try #require(receipt.capture?.generated)
        #expect(generated.body == "Newer body")
        #expect(generated.ocrText == "Newer OCR")
        #expect(generated.tags == ["newer tag"])
        #expect(generated.taggingProcessed == true)
        #expect(generated.taggingInputFingerprint == "exact-old-input")
        #expect(try fixture.server.baseline().captures.first?.seenCount == 1)
        #expect(try reopened.pendingOperations().isEmpty)
    }

    @Test func metadataCapabilityFailuresNeverSubmitAndReopeningRetainsCanonicalQueue() async throws
    {
        for mode in [CapabilityAuthority.Mode.absent, .malformed, .wrongVersion, .wrongPrincipal] {
            let fixture = try AsyncHTTPFixture()
            defer { fixture.clean() }
            let authority = CapabilityAuthority(handler: fixture.handler, mode: mode)
            let host = try await SyntheticHTTPHost.start(
                handler: fixture.handler, execute: { authority.handle($0) })
            defer { host.stop() }
            let client = try fixture.client()
            let capture = SharedCapture(
                source: CaptureSource(kind: .text, selection: "Synthetic compatibility"),
                metadata: CaptureMetadata(sourceAppBundleID: "test.original"))
            let operation = try client.enqueue(captureID: capture.id, mutation: .create(capture))
            let bytes = try SyncDatabase.encode(operation)
            let actions = AsyncHTTPActions(
                transport: try fixture.transport(host), credential: { fixture.token })
            let expected: SyncHTTPError =
                mode == .absent || mode == .wrongVersion
                ? .unsupportedVersion : .invalidResponse
            await #expect(throws: expected) {
                try await fixture.transport(host).importBaseline(credential: { fixture.token })
            }
            await #expect(throws: expected) { try await actions.request(.apply(operation)) }
            #expect(host.applyBodies.isEmpty)
            #expect(try fixture.server.baseline().captures.isEmpty)
            let reopened = try fixture.client()
            #expect(try reopened.pendingOperations() == [operation])
            #expect(try SyncDatabase.encode(reopened.pendingOperations()[0]) == bytes)
            authority.mode = .current
            let importBaseline = try await fixture.transport(host)
                .importBaseline(credential: { fixture.token })
            #expect(importBaseline.captures.isEmpty)
            try await reopened.push(to: fixture.transport(host), credential: { fixture.token })
            #expect(try reopened.pendingOperations().isEmpty)
            #expect(try fixture.server.baseline().captures.first?.metadata == capture.metadata)
            #expect(host.applyBodies.count == 1)
        }
    }

    @Test func upgradedEditsProbeEveryTimeAndDowngradeRejectsVersionTwoBeforeMutation() async throws
    {
        let fixture = try AsyncHTTPFixture()
        defer { fixture.clean() }
        let authority = CapabilityAuthority(handler: fixture.handler, mode: .absent)
        let host = try await SyntheticHTTPHost.start(
            handler: fixture.handler, execute: { authority.handle($0) })
        defer { host.stop() }
        let client = try fixture.client()
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "Legacy create"))
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        try await client.push(to: fixture.transport(host), credential: { fixture.token })
        #expect(host.requestCount == 1)
        #expect(try client.pendingOperations().isEmpty)
        let edits = [
            CaptureEdit(
                metadata: CaptureMetadataPatch(
                    reminder: .set(Date(timeIntervalSinceReferenceDate: 123.456789)))),
            CaptureEdit(sourceContent: SourceContentPatch(title: "Filled original title")),
            CaptureEdit(generatedPatch: GeneratedContentPatch(body: .set("Independent body"))),
        ]
        for edit in edits {
            let operation = try client.enqueue(captureID: capture.id, mutation: .edit(edit))
            let before = try fixture.server.baseline()
            let count = host.applyBodies.count
            authority.mode = .absent
            await #expect(throws: SyncHTTPError.unsupportedVersion) {
                try await client.push(to: fixture.transport(host), credential: { fixture.token })
            }
            #expect(host.applyBodies.count == count)
            #expect(try client.pendingOperations() == [operation])
            authority.mode = .downgradedAfterProbe
            await #expect(throws: SyncHTTPError.unsupportedVersion) {
                try await client.push(to: fixture.transport(host), credential: { fixture.token })
            }
            #expect(try fixture.server.baseline().captures == before.captures)
            #expect(try client.pendingOperations() == [operation])
            authority.mode = .current
            try await client.push(to: fixture.transport(host), credential: { fixture.token })
            #expect(try client.pendingOperations().isEmpty)
            let envelope = try SyncDatabase.decode(SyncHTTPEnvelope.self, host.applyBodies.last!)
            #expect(envelope.version == 2)
        }
        let accepted = try #require(try client.captures().first)
        #expect(accepted.metadata?.reminderAt == Date(timeIntervalSinceReferenceDate: 123.456789))
        #expect(accepted.source.title == "Filled original title")
        #expect(accepted.generated.body == "Independent body")
    }

    @Test func lostResponseRetriesExactOperationAfterReopen() async throws {
        let fixture = try AsyncHTTPFixture()
        defer { fixture.clean() }
        let host = try await SyntheticHTTPHost.start(handler: fixture.handler)
        defer { host.stop() }
        host.fault = .dropApply
        let transport = try fixture.transport(host)
        let operation: SyncOperation
        do {
            let client = try fixture.client()
            var capture = SharedCapture(
                source: CaptureSource(kind: .text, selection: "Synthetic lost response"),
                createdAt: Date(timeIntervalSinceReferenceDate: 123_456_789.12345679),
                metadata: CaptureMetadata(
                    updatedAt: Date(timeIntervalSinceReferenceDate: 123_456_791.98765432),
                    reminderAt: Date(timeIntervalSinceReferenceDate: 123_456_799.23456789),
                    sourceAppBundleID: "test.synthetic-mac-app",
                    unknownFields: ["future": .string("retained")]))
            capture.unknownFields["futureRecord"] = .array([.null, .bool(true)])
            operation = try client.enqueue(captureID: capture.id, mutation: .create(capture))
            await #expect(throws: SyncError.transportDisconnected) {
                try await client.push(to: transport, credential: { fixture.token })
            }
            #expect(try client.pendingOperations() == [operation])
        }
        #expect(try fixture.server.baseline().captures.count == 1)
        let reopened = try fixture.client()
        #expect(try reopened.pendingOperations() == [operation])
        let receipts = try await reopened.syncOnce(using: transport, credential: { fixture.token })
        #expect(receipts.first?.operationID == operation.id)
        #expect(try reopened.pendingOperations().isEmpty)
        #expect(try fixture.server.baseline().captures.first?.seenCount == 1)
        #expect(try fixture.server.changes(after: 0, limit: 100).changes.count == 1)
        #expect(host.applyBodies.count == 2)
        #expect(host.applyBodies.first == host.applyBodies.last)
        let synced = try #require(try reopened.captures().first)
        #expect(synced.createdAt == Date(timeIntervalSinceReferenceDate: 123_456_789.12345679))
        #expect(
            synced.metadata?.updatedAt == Date(timeIntervalSinceReferenceDate: 123_456_791.98765432)
        )
        #expect(synced.metadata?.sourceAppBundleID == "test.synthetic-mac-app")
        #expect(synced.metadata?.unknownFields["future"] == .string("retained"))
        #expect(synced.unknownFields["futureRecord"] == .array([.null, .bool(true)]))
    }

    @Test func cancellationInterruptsHeldResponseAndPreservesQueueOnReopen() async throws {
        let fixture = try AsyncHTTPFixture()
        defer { fixture.clean() }
        let host = try await SyntheticHTTPHost.start(handler: fixture.handler)
        defer { host.stop() }
        host.fault = .holdApply
        let transport = try fixture.transport(host)
        let operation: SyncOperation
        let laterEdit: SyncOperation
        do {
            let client = try fixture.client()
            let capture = SharedCapture(
                source: CaptureSource(kind: .text, selection: "Synthetic cancelled response"))
            operation = try client.enqueue(captureID: capture.id, mutation: .create(capture))
            let task = Task { try await client.push(to: transport, credential: { fixture.token }) }
            try await host.waitForApply()
            laterEdit = try client.enqueue(
                captureID: capture.id,
                mutation: .edit(CaptureEdit(note: NoteEdit("Queued during request"))))
            let cancelledAt = ContinuousClock.now
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(cancelledAt.duration(to: .now) < .seconds(2))
            #expect(try client.pendingOperations() == [operation, laterEdit])
            #expect(try client.cursor() == 0)
        }
        let reopened = try fixture.client()
        #expect(try reopened.pendingOperations() == [operation, laterEdit])
        try await reopened.syncOnce(using: transport, credential: { fixture.token })
        #expect(try reopened.pendingOperations().isEmpty)
        #expect(try fixture.server.baseline().captures.first?.seenCount == 1)
        #expect(try fixture.server.baseline().captures.first?.note == "Queued during request")
        #expect(host.applyBodies.count == 3)
        #expect(host.applyBodies[0] == host.applyBodies[1])
    }

    @Test func multiChunkImageUploadsAndVerifiedDownloadUseAsyncPath() async throws {
        let fixture = try AsyncHTTPFixture()
        defer { fixture.clean() }
        let host = try await SyntheticHTTPHost.start(handler: fixture.handler)
        defer { host.stop() }
        let transport = try fixture.transport(host)
        let client = try fixture.client()
        let bytes = Data(repeating: 0x5a, count: 150_000)
        let blob = BlobReference(data: bytes)
        try client.blobs.receive(blob, offset: 0, chunk: bytes, final: true)
        let capture = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        try await client.push(to: transport, credential: { fixture.token })
        #expect(try fixture.server.download(blob) == bytes)
        let reader = try SyncClient(
            databaseURL: fixture.root.appendingPathComponent("reader.sqlite"),
            blobDirectory: fixture.root.appendingPathComponent("reader-blobs"),
            deviceID: fixture.device, binding: fixture.binding)
        try await reader.pull(from: transport, credential: { fixture.token })
        #expect(try reader.blobs.read(blob) == bytes)
        #expect(try reader.captures().first?.id == capture.id)
        #expect(try reader.cursor() == 1)
    }

    @Test func redirectsNeverSendCredentialsToTarget() async throws {
        let fixture = try AsyncHTTPFixture()
        defer { fixture.clean() }
        let target = try await SyntheticHTTPHost.start(handler: fixture.handler)
        defer { target.stop() }
        let source = try await SyntheticHTTPHost.start(handler: fixture.handler)
        defer { source.stop() }
        source.fault = .redirect(target.endpoint)
        let client = try fixture.client()
        let transport = try fixture.transport(source)
        await #expect(throws: SyncConnectionError.redirectRefused) {
            try await client.pull(from: transport, credential: { fixture.token })
        }
        #expect(source.requestCount == 1)
        #expect(target.requestCount == 0)
        #expect(try client.cursor() == 0)
    }

    @Test func responseBoundsApplyToDeclaredAndChunkedBodies() async throws {
        let fixture = try AsyncHTTPFixture()
        defer { fixture.clean() }
        let host = try await SyntheticHTTPHost.start(handler: fixture.handler)
        defer { host.stop() }
        let transport = try fixture.transport(host, limit: 128)
        let client = try fixture.client()
        for fault in [SyntheticHTTPHost.Fault.oversizedLength, .chunkedOverflow] {
            host.fault = fault
            await #expect(throws: SyncConnectionError.responseTooLarge) {
                try await client.pull(from: transport, credential: { fixture.token })
            }
            #expect(try client.cursor() == 0)
        }
    }

    @Test func authErrorsAreExplicitEvenForProxyHTMLAndDoNotAcknowledge() async throws {
        let fixture = try AsyncHTTPFixture()
        defer { fixture.clean() }
        let host = try await SyntheticHTTPHost.start(handler: fixture.handler)
        defer { host.stop() }
        let transport = try fixture.transport(host)
        let client = try fixture.client()
        let capture = SharedCapture(
            source: CaptureSource(kind: .text, selection: "Private synthetic content"))
        let operation = try client.enqueue(captureID: capture.id, mutation: .create(capture))
        for (status, error) in [(401, SyncHTTPError.unauthorized), (403, .forbidden)] {
            host.fault = .status(status)
            await #expect(throws: error) {
                try await client.push(to: transport, credential: { fixture.token })
            }
            #expect(try client.pendingOperations() == [operation])
            #expect(!error.localizedDescription.contains(fixture.token))
        }
        #expect(try fixture.server.baseline().captures.isEmpty)
    }

    @Test func bindingMismatchAndUsedUnboundGuardFailBeforeNetwork() async throws {
        let fixture = try AsyncHTTPFixture()
        defer { fixture.clean() }
        let host = try await SyntheticHTTPHost.start(handler: fixture.handler)
        defer { host.stop() }
        let wrong = try URLSessionSyncTransport(
            endpoint: host.endpoint,
            binding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()),
            deviceID: fixture.device, policy: .syntheticLoopback)
        let client = try fixture.client()
        await #expect(throws: SyncBindingError.mismatch) {
            try await client.pull(from: wrong, credential: { fixture.token })
        }
        #expect(host.requestCount == 0)
        let unboundURL = fixture.root.appendingPathComponent("unbound.sqlite")
        let unboundBlobs = fixture.root.appendingPathComponent("unbound-blobs")
        let local = try SyncClient(databaseURL: unboundURL, blobDirectory: unboundBlobs)
        let capture = SharedCapture(
            source: CaptureSource(kind: .text, selection: "Existing unbound work"))
        let operation = try local.enqueue(captureID: capture.id, mutation: .create(capture))
        #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
            try SyncClient(
                databaseURL: unboundURL, blobDirectory: unboundBlobs, binding: fixture.binding)
        }
        #expect(try local.pendingOperations() == [operation])
    }

    @Test func endpointPolicyAndDisposableCredentialSetup() throws {
        for address in [
            "http://sync.example.com/v1/sync", "https://u:p@sync.example.com/v1/sync",
            "https://sync.example.com/v1/sync?token=a", "https://sync.example.com/v1/sync#fragment",
            "https://sync.example.com/other", "https://sync.example.com:0/v1/sync",
        ] {
            #expect(throws: SyncConnectionError.invalidEndpoint) {
                try SyncEndpointPolicy.validate(URL(string: address)!)
            }
        }
        #expect(throws: SyncConnectionError.invalidEndpoint) {
            try SyncEndpointPolicy.validate(
                URL(string: "http://192.0.2.1/v1/sync")!, policy: .syntheticLoopback)
        }
        var draft = SyncEnrollmentDraft()
        draft.address = "https://sync.example.invalid/v1/sync"
        draft.serviceID = UUID().uuidString
        draft.libraryID = UUID().uuidString
        draft.deviceID = UUID().uuidString
        draft.credential = "synthetic-setup-only"
        let enrollment = try draft.validate()
        let store = MemorySyncCredentialStore()
        #expect(throws: SyncConnectionError.credentialUnavailable) {
            try store.read(for: enrollment)
        }
        try store.save(draft.credential, for: enrollment)
        #expect(try store.read(for: enrollment) == draft.credential)
        try store.save("synthetic-replacement", for: enrollment)
        #expect(try store.read(for: enrollment) == "synthetic-replacement")
        try store.remove(for: enrollment)
        #expect(throws: SyncConnectionError.credentialUnavailable) {
            try store.read(for: enrollment)
        }
        #expect(try draft.verifyTemporarySetup() == 1)
        #expect(throws: SyncConnectionError.enrollmentDisabled) {
            try SyncEnrollmentActivation.requireReady()
        }
        draft.credential = "unsafe\r\nAuthorization: injected"
        #expect(throws: SyncConnectionError.invalidCredential) { try draft.validate() }
    }
}

private struct AsyncHTTPFixture: Sendable {
    let root: URL
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let device = UUID()
    let token = "synthetic-loopback-credential"
    let server: SyncServer

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capd-async-\(UUID())")
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
    }

    var handler: SyncHTTPHandler {
        SyncHTTPHandler(
            serviceID: binding.serviceID,
            authorizer: SyntheticAuthorizer(
                token: token,
                principal: SyncPrincipal(
                    serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: device)),
            server: { _ in server })
    }

    func client() throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("client.sqlite"),
            blobDirectory: root.appendingPathComponent("client-blobs"), deviceID: device,
            binding: binding)
    }

    func transport(_ host: SyntheticHTTPHost, limit: Int = SyncHTTPHandler.maximumBodyBytes) throws
        -> URLSessionSyncTransport
    {
        try URLSessionSyncTransport(
            endpoint: host.endpoint, binding: binding, deviceID: device,
            policy: .syntheticLoopback, maximumResponseBytes: limit, timeout: 10)
    }

    func pendingBytes() throws -> [Data] {
        let database = try DatabaseQueue(path: root.appendingPathComponent("client.sqlite").path)
        return try database.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct SyntheticAuthorizer: SyncAuthorizer {
    let token: String
    let principal: SyncPrincipal
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        bearerCredential == token ? principal : nil
    }
}

private final class SyntheticHTTPHost: @unchecked Sendable {
    enum Fault: Sendable {
        case none, dropApply, holdApply
        case redirect(URL)
        case oversizedLength, chunkedOverflow
        case status(Int)
    }

    private let lock = NSLock()
    private let listener: NWListener
    private let execute: @Sendable (SyncHTTPRequest) -> SyncHTTPResponse
    private let queue = DispatchQueue(label: "capd.synthetic-http.\(UUID())")
    private var connections: [NWConnection] = []
    private var nextFault = Fault.none
    private var bodies: [Data] = []
    private var requests = 0
    var endpoint: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/v1/sync")! }
    var applyBodies: [Data] { lock.withLock { bodies } }
    var requestCount: Int { lock.withLock { requests } }
    var fault: Fault {
        get { lock.withLock { nextFault } }
        set { lock.withLock { nextFault = newValue } }
    }

    private init(execute: @escaping @Sendable (SyncHTTPRequest) -> SyncHTTPResponse) throws {
        self.execute = execute
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(
        handler: SyncHTTPHandler,
        execute: (@Sendable (SyncHTTPRequest) -> SyncHTTPResponse)? = nil
    ) async throws -> SyntheticHTTPHost {
        let host = try SyntheticHTTPHost(execute: execute ?? { handler.handle($0) })
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            host.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    host.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    host.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            host.listener.newConnectionHandler = { connection in
                host.lock.withLock { host.connections.append(connection) }
                connection.start(queue: host.queue)
                host.receive(connection, buffer: Data())
            }
            host.listener.start(queue: host.queue)
        }
        return host
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            for connection in connections {
                connection.cancel()
            }
            connections.removeAll()
        }
    }

    func waitForApply() async throws {
        for _ in 0..<300 {
            if !applyBodies.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SyncError.transportDisconnected
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil, buffer.count <= SyncHTTPHandler.maximumBodyBytes + 16_384 else {
                connection.cancel()
                return
            }
            if let split = buffer.range(of: Data("\r\n\r\n".utf8)),
                let head = String(data: buffer[..<split.lowerBound], encoding: .utf8)
            {
                let lines = head.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pieces = line.split(separator: ":", maxSplits: 1)
                    if pieces.count == 2 {
                        headers[String(pieces[0])] = pieces[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                let count =
                    headers.first(where: { $0.key.lowercased() == "content-length" }).flatMap {
                        Int($0.value)
                    } ?? 0
                if buffer.count - split.upperBound >= count {
                    let method = lines.first?.split(separator: " ").first.map(String.init) ?? ""
                    let request = SyncHTTPRequest(
                        method: method, path: "/v1/sync", headers: headers,
                        body: buffer.subdata(in: split.upperBound..<(split.upperBound + count)))
                    self.respond(connection, request: request)
                    return
                }
            }
            if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
        }
    }

    private func respond(_ connection: NWConnection, request: SyncHTTPRequest) {
        let isApply: Bool
        if let envelope = try? JSONDecoder().decode(SyncHTTPEnvelope.self, from: request.body),
            case .apply = envelope.action
        {
            isApply = true
        } else {
            isApply = false
        }
        let fault = lock.withLock {
            requests += 1
            let fault = nextFault
            switch fault {
            case .dropApply, .holdApply:
                if isApply { nextFault = .none }
            default: nextFault = .none
            }
            return fault
        }
        let bytes: Data
        switch fault {
        case .redirect(let endpoint):
            bytes = Data(
                "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(endpoint.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    .utf8)
        case .oversizedLength:
            bytes = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n"
                    .utf8)
        case .chunkedOverflow:
            bytes = Data(
                ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n100\r\n"
                    + String(repeating: "x", count: 256) + "\r\n0\r\n\r\n").utf8)
        case .status(let status):
            bytes = Data(
                "HTTP/1.1 \(status) Error\r\nContent-Type: text/html\r\nContent-Length: 4\r\nConnection: close\r\n\r\noops"
                    .utf8)
        default:
            let response = execute(request)
            if isApply { lock.withLock { bodies.append(request.body) } }
            if isApply, case .dropApply = fault {
                connection.cancel()
                return
            }
            if isApply, case .holdApply = fault { return }
            var head =
                "HTTP/1.1 \(response.status) Response\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
            for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
            bytes = Data((head + "\r\n").utf8) + response.body
        }
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class CapabilityAuthority: @unchecked Sendable {
    enum Mode: Sendable {
        case current, absent, malformed, wrongVersion, wrongPrincipal, downgradedAfterProbe
        case processingAbsent, processingMalformed, processingWrongVersion, processingDowngrade
    }
    private let handler: SyncHTTPHandler
    private let lock = NSLock()
    private var storedMode: Mode
    var mode: Mode {
        get { lock.withLock { storedMode } }
        set { lock.withLock { storedMode = newValue } }
    }
    init(handler: SyncHTTPHandler, mode: Mode) {
        self.handler = handler
        storedMode = mode
    }
    func handle(_ request: SyncHTTPRequest) -> SyncHTTPResponse {
        let mode = self.mode
        if let envelope = try? SyncDatabase.decode(SyncHTTPEnvelope.self, request.body),
            (mode == .downgradedAfterProbe && envelope.version != 1)
                || (mode == .processingDowngrade && envelope.version > 2)
        {
            return SyncHTTPResponse(
                status: 400, headers: ["Content-Type": "application/json"],
                body: try! SyncDatabase.encode(
                    SyncHTTPReply(version: 1, principal: nil, result: .failure(.unsupportedVersion))
                ))
        }
        let actual = handler.handle(request)
        guard actual.status == 200, mode != .current, mode != .downgradedAfterProbe,
            mode != .processingDowngrade
        else {
            return actual
        }
        var object = try! JSONSerialization.jsonObject(with: actual.body) as! [String: Any]
        switch mode {
        case .absent: object.removeValue(forKey: "metadataContractVersion")
        case .malformed: object["metadataContractVersion"] = "unsupported"
        case .wrongVersion: object["metadataContractVersion"] = 9
        case .processingAbsent: object.removeValue(forKey: "generatedProcessingContractVersion")
        case .processingMalformed: object["generatedProcessingContractVersion"] = "unsupported"
        case .processingWrongVersion: object["generatedProcessingContractVersion"] = 9
        case .wrongPrincipal:
            var principal = object["principal"] as! [String: Any]
            principal["serviceID"] = UUID().uuidString
            object["principal"] = principal
        default: break
        }
        return SyncHTTPResponse(
            status: actual.status, headers: actual.headers,
            body: try! JSONSerialization.data(withJSONObject: object))
    }
}
