import CapdSync
import Foundation
import GRDB
import Synchronization
import Testing

@testable import CapdCLI
@testable import CapdKit

@Suite("CLI bound Mac runtime", .timeLimit(.minutes(1)))
struct CLISyncRuntimeTests {
    @Test(.serialized, arguments: [Duration.milliseconds(75), .zero])
    func postCommandFlushRetriesBusyLeaseWithoutRecreatingOperation(deadline: Duration) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-cli-busy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root.appendingPathComponent("mac"))
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let device = UUID()
        let enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.invalid/v1/sync")!, binding: binding,
            deviceID: device)
        _ = try Store(paths: paths, syncBinding: binding, deviceID: device)
        try MacSyncConfiguration(enrollment: enrollment).install(paths: paths)
        let server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        let credentials = MemorySyncCredentialStore()
        try credentials.save("synthetic-cli-credential", for: enrollment)
        let wire = CLIFlushWire(
            binding: binding, deviceID: device,
            handler: SyncHTTPHandler(
                serviceID: binding.serviceID,
                authorizer: CLIFlushAuthorizer(
                    principal: SyncPrincipal(
                        serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: device
                    )),
                server: { _ in server }))
        let session = try MacLibrarySession.open(
            paths: paths, credentials: credentials, transport: wire)
        _ = try CaptureService(store: session.store).ingest(
            CaptureRequest(text: "Concurrent CLI capture"))
        let operation = try #require(try session.store.syncClient?.pendingOperations().first)
        let lease = Mutex<MacSyncLease?>(try #require(try MacSyncLease.acquire(paths: paths)))
        let before = try await session.store.reader.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
        let blocked = await CLISyncSessions.flush(
            try #require(session.runtime), within: deadline)
        let expectedIssue =
            blocked.phase == .busy
            ? "Another Capd process is synchronizing this library. Saved changes remain queued."
            : "Sync timed out. Saved changes remain queued."
        // The timer can finish before the contended lease snapshot returns.
        #expect(blocked.phase == .busy || blocked.phase == .attention)
        #expect(blocked.issue == expectedIssue)
        #expect(blocked.pending == 1)
        #expect(await wire.operations.isEmpty)
        #expect(
            try await session.store.reader.read {
                try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
            } == before)
        let release = Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            lease.withLock { $0 = nil }
        }
        CLISyncSessions.remember(session)
        CLISyncSessions.flush()
        await release.value
        #expect(try session.store.syncClient?.pendingOperations().isEmpty == true)
        #expect(try server.baseline().captures.count == 1)
        #expect(try server.baseline().deviceSequences[device] == 1)
        #expect(await wire.operations == [operation])
    }

    @Test(arguments: ["corrupt", "unavailable"])
    func activationStoreFailuresUseStoreUnavailableExitCode(failure: String) throws {
        try withScratchRoot { root in
            let paths = StoragePaths(root: root)
            try paths.createDirectories()
            if failure == "corrupt" {
                try Data("not a database".utf8).write(to: paths.databaseURL)
            } else {
                try FileManager.default.createDirectory(
                    at: paths.databaseURL, withIntermediateDirectories: true)
            }
            let enrollment = try SyncEnrollment(
                endpoint: URL(string: "https://sync.example.invalid/v1/sync")!,
                binding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()), deviceID: UUID())
            let file = root.appendingPathComponent("enrollment.json")
            try JSONEncoder().encode(enrollment).write(to: file)
            let result = try capd(["sync", "activate", "--enrollment", file.path], root: root)
            #expect(result.status == 3)
            #expect(result.stderr.contains("store is unavailable"))
            #expect(result.stdout.isEmpty)
            #expect(
                !FileManager.default.fileExists(atPath: MacSyncConfiguration.url(paths: paths).path)
            )
        }
    }

    @Test func activationClassificationPreservesConnectionAndEnrollmentErrors() throws {
        let errors: [any Error] = [
            SyncHTTPError.unauthorized, SyncHTTPError.forbidden, SyncHTTPError.unavailable,
            SyncConnectionError.credentialUnavailable, SyncConnectionError.invalidEndpoint,
            SyncError.transportDisconnected, MacSyncError.invalidConfiguration,
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Synthetic invalid enrollment")),
        ]
        for original in errors {
            do {
                try Sync.checkActivationResult(.failure(original))
                Issue.record("Activation failure was discarded")
            } catch {
                #expect(ObjectIdentifier(type(of: error)) == ObjectIdentifier(type(of: original)))
                #expect(String(describing: error) == String(describing: original))
            }
        }
        for original: any Error in [
            StoreError.databaseIsNewerThanApp, SyncBindingError.mismatch,
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError),
        ] {
            do {
                try Sync.checkActivationResult(.failure(original))
                Issue.record("Activation storage failure was discarded")
            } catch let error as CLIError {
                #expect(error.code == 3)
                #expect(error.message.contains("store is unavailable"))
            }
        }
        try Sync.checkActivationResult(.success(()))
    }

    @Test func unavailableSyncStoreUsesDocumentedExitCode() throws {
        try withScratchRoot { root in
            let paths = StoragePaths(root: root)
            try paths.createDirectories()
            try Data("not a database".utf8).write(to: paths.databaseURL)
            for command in ["status", "run"] {
                let result = try capd(["sync", command], root: root)
                #expect(result.status == 3)
                #expect(result.stderr.contains("store is unavailable"))
                #expect(result.stdout.isEmpty)
            }
        }
    }

    @Test(arguments: ["missing", "corrupt", "mismatch"])
    func configurationFailuresUseStoreUnavailableExitCode(failure: String) throws {
        try withScratchRoot { root in
            let paths = StoragePaths(root: root)
            try paths.createDirectories()
            if failure != "missing" {
                if failure == "mismatch" { _ = try Store(paths: paths) }
                let enrollment = try SyncEnrollment(
                    endpoint: URL(string: "https://sync.example.invalid/v1/sync")!,
                    binding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()),
                    deviceID: UUID())
                try MacSyncConfiguration(enrollment: enrollment, enabled: false).install(
                    paths: paths)
                if failure == "corrupt" {
                    try Data("not a database".utf8).write(to: paths.databaseURL)
                }
            }
            let configuration = try? Data(contentsOf: MacSyncConfiguration.url(paths: paths))
            for command in ["deactivate", "resume"] {
                let result = try capd(["sync", command], root: root)
                #expect(result.status == 3)
                #expect(result.stderr.contains("store is unavailable"))
                #expect(result.stdout.isEmpty)
                #expect(
                    (try? Data(contentsOf: MacSyncConfiguration.url(paths: paths))) == configuration
                )
            }
        }
    }

    @Test func partialWriteErrorsFlushBeforeReturningTheirExitCode() throws {
        try withScratchRoot { root in
            let paths = StoragePaths(root: root)
            let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
            let device = UUID()
            let store = try Store(paths: paths, syncBinding: binding, deviceID: device)
            let enrollment = try SyncEnrollment(
                endpoint: URL(string: "https://sync.example.invalid/v1/sync")!, binding: binding,
                deviceID: device)
            try MacSyncConfiguration(enrollment: enrollment).install(paths: paths)
            let bulk = try capd(
                ["add", "-", "--no-fetch"],
                stdin: "https://example.invalid/valid\nhttps:///missing-host\n", root: root)
            #expect(bulk.status == 2)
            #expect(bulk.stderr.contains("credential"))
            #expect(try store.syncClient?.pendingOperations().count == 1)
            let imported = try capd(
                ["import", "pinboard", "-"],
                stdin: #"[{"href":"https://example.invalid/imported"},{"href":"not a link"}]"#,
                root: root)
            #expect(imported.status == 2)
            #expect(imported.stderr.contains("credential"))
            #expect(try store.syncClient?.pendingOperations().count == 2)
            let captures = try store.reader.read { try Capture.fetchAll($0) }
            let id = try #require(captures.first?.id)
            let removed = try capd(["rm", String(id), "999999"], root: root)
            #expect(removed.status == 1)
            #expect(removed.stderr.contains("credential"))
            #expect(try SearchService(store: store).capture(id: id) == nil)
            #expect(try store.syncClient?.pendingOperations().count == 3)
        }
    }
    @Test func pausedCLIProcessesShareAppAndAgentOutbox() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/capd-cli-bound-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let device = UUID()
        let store = try Store(paths: paths, syncBinding: binding, deviceID: device)
        let enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.invalid/v1/sync")!, binding: binding,
            deviceID: device)
        try MacSyncConfiguration(enrollment: enrollment, enabled: false).install(paths: paths)
        let app = try MacLibrarySession.open(paths: paths)
        let agent = try MacLibrarySession.open(paths: paths)
        _ = try CaptureService(store: app.store).ingest(CaptureRequest(text: "App kestrel"))
        let results = try await withThrowingTaskGroup(of: CLIRun.self) { group in
            for index in 0..<6 {
                group.addTask { try capd(["add", "CLI pangolin \(index)", "--json"], root: root) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0.status == 0 && $0.stderr.isEmpty })
        #expect(try store.syncClient?.pendingOperations().map(\.sequence) == Array(1...7))
        #expect(app.store.syncClient?.deviceID == device)
        #expect(agent.store.syncClient?.deviceID == device)
        #expect(try SearchService(store: agent.store).totalCaptureCount() == 7)
        let status = try capd(["sync", "status"], root: root)
        #expect(status.status == 0)
        let json = try jsonObject(status.stdout)
        #expect(json["phase"] as? String == "paused")
        #expect(json["pending"] as? Int == 7)
        let run = try capd(["sync", "run"], root: root)
        #expect(run.status == 0)
        #expect(try jsonObject(run.stdout)["phase"] as? String == "paused")
        let original = try await store.reader.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
        let reader = try MacLibrarySession.readOnlyStore(paths: paths)
        #expect(reader.syncClient == nil)
        #expect(throws: DatabaseError.self) {
            try reader.dbPool.write { try $0.execute(sql: "DELETE FROM captures") }
        }
        #expect(try SearchService(store: reader).search("pangolin").count == 6)
        #expect(
            try await store.reader.read {
                try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
            } == original)
        #expect(try capd(["sync", "deactivate"], root: root).status == 0)
        #expect(try capd(["sync", "resume"], root: root).status == 0)
        #expect(try MacSyncConfiguration.load(paths: paths)?.enabled == true)
        #expect(try capd(["sync", "deactivate"], root: root).status == 0)
        #expect(try MacSyncConfiguration.load(paths: paths)?.enabled == false)
        #expect(try store.syncClient?.pendingOperations().count == 7)
    }

    @Test func invalidOrUnboundConfigurationCannotFallBackToLocalWrites() throws {
        try withScratchRoot { root in
            let paths = StoragePaths(root: root)
            let local = try Store(paths: paths)
            let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
            let enrollment = try SyncEnrollment(
                endpoint: URL(string: "https://sync.example.invalid/v1/sync")!, binding: binding,
                deviceID: UUID())
            try MacSyncConfiguration(enrollment: enrollment, enabled: false).install(paths: paths)
            #expect(try capd(["add", "Must not fall back"], root: root).status == 3)
            for command in ["status", "run"] {
                #expect(try capd(["sync", command], root: root).status == 3)
            }
            #expect(try SearchService(store: local).totalCaptureCount() == 0)
            let unsafe =
                "{\"version\":1,\"endpoint\":\"http://127.0.0.1:1234/v1/sync\",\"binding\":{\"libraryID\":\"\(binding.libraryID)\",\"serviceID\":\"\(binding.serviceID)\"},\"deviceID\":\"\(enrollment.deviceID)\",\"enabled\":false}"
            try Data(unsafe.utf8).write(to: MacSyncConfiguration.url(paths: paths))
            #expect(try capd(["add", "Unsafe endpoint"], root: root).status == 3)
            for command in ["status", "run"] {
                #expect(try capd(["sync", command], root: root).status == 3)
            }
            #expect(try SearchService(store: local).totalCaptureCount() == 0)
        }
    }
}

private struct CLIFlushAuthorizer: SyncAuthorizer {
    let principal: SyncPrincipal
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        bearerCredential == "synthetic-cli-credential" ? principal : nil
    }
}

private actor CLIFlushWire: AsyncSyncTransport {
    nonisolated let binding: SyncLibraryBinding
    nonisolated let deviceID: UUID
    let handler: SyncHTTPHandler
    var operations: [SyncOperation] = []
    init(binding: SyncLibraryBinding, deviceID: UUID, handler: SyncHTTPHandler) {
        self.binding = binding
        self.deviceID = deviceID
        self.handler = handler
    }
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        let envelope = try JSONDecoder().decode(SyncHTTPEnvelope.self, from: request.body)
        if case .apply(let operation) = envelope.action { operations.append(operation) }
        return handler.handle(request)
    }
}
