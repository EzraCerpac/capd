import CryptoKit
import Darwin
import Foundation
import GRDB
import Testing

@testable import CapdKit
@testable import CapdSync

@Suite("Synthetic Mac import over the standalone HTTP host")
struct MigrationHTTPIntegrationTests {
    @Test func importedBaselineAndExactRetrySurviveHTTPHostRestart() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/capd-import-http-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root.appendingPathComponent("mac"))
        let store = try Store(paths: paths)
        try mark(paths.root)
        let imagePath = "nested/kestrel.png"
        let imageURL = paths.assetURL(forRelativePath: imagePath)
        try FileManager.default.createDirectory(
            at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let imageBytes = Data(repeating: 0x5a, count: 150_000)
        try imageBytes.write(to: imageURL)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = try store.upsertCapture(
            Capture(
                id: 42, kind: .image, title: "Synthetic HTTP kestrel", note: "Original Mac note",
                body: "Searchable pangolin body", ocrText: "Axolotl OCR", assetPath: imagePath,
                sourceAppBundleID: "example.synthetic", tags: "manual", tagsVersion: -1,
                rating: 5,
                contentHash: SHA256.hash(data: imageBytes).map { String(format: "%02x", $0) }
                    .joined(),
                reminderAt: now.addingTimeInterval(100), createdAt: now,
                lastSeenAt: now.addingTimeInterval(20), seenCount: 7)
        ).capture
        _ = try store.upsertCapture(
            Capture(
                id: 81, kind: .text, title: "Generated HTTP source", selection: "Synthetic text",
                tags: "generated", tagsVersion: 2, contentHash: "synthetic-http-text",
                createdAt: now)
        )
        let sourceBackup = root.appendingPathComponent("source-backup")
        try migration([
            "backup", paths.root.path, "--database", "capd.sqlite",
            "--destination", sourceBackup.path,
        ])
        let prepared = root.appendingPathComponent("prepared-mac")
        try migration(["restore", sourceBackup.path, "--destination", prepared.path])
        try migration(["backfill", prepared.path, "--database", "capd.sqlite"])
        let preparedDatabase = try DatabaseQueue(
            path: prepared.appendingPathComponent("capd.sqlite").path)
        let identityValue = try await preparedDatabase.read { db in
            try String.fetchOne(db, sql: "SELECT global_id FROM sync_capture_ids WHERE local_id=42")
        }
        let identityString = try #require(identityValue)
        let identity = try #require(UUID(uuidString: identityString))
        let archive = root.appendingPathComponent("import-archive")
        try migration([
            "backup", prepared.path, "--database", "capd.sqlite",
            "--destination", archive.path,
        ])

        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let deviceID = UUID()
        let token = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "").lowercased()
        let config = root.appendingPathComponent("enrollment.json")
        func writeEnrollment(revoked: Bool) throws {
            let digest = SHA256.hash(data: Data(token.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let object: [String: Any] = [
                "serviceID": binding.serviceID.uuidString,
                "enrollments": [
                    [
                        "libraryID": binding.libraryID.uuidString, "deviceID": deviceID.uuidString,
                        "credentialSHA256": digest, "revoked": revoked,
                    ]
                ],
            ]
            try JSONSerialization.data(withJSONObject: object).write(to: config, options: .atomic)
        }
        try writeEnrollment(revoked: false)
        let dataRoot = root.appendingPathComponent("host-data")
        let host = IntegrationHTTPHost(
            binary: repo.appendingPathComponent(
                "Packages/CapdSyncServer/.build/debug/capd-sync-server"),
            config: config, data: dataRoot, log: root.appendingPathComponent("host.log"))
        defer { try? host.stop() }
        func transport() throws -> URLSessionSyncTransport {
            try URLSessionSyncTransport(
                endpoint: #require(host.endpoint), binding: binding, deviceID: deviceID,
                policy: .syntheticLoopback, timeout: 10)
        }
        try await host.start()
        let empty = try await AsyncHTTPActions(transport: transport(), credential: { token })
            .baseline()
        #expect(empty.captures.isEmpty)
        try host.stop()
        let authority = dataRoot.appendingPathComponent(binding.libraryID.uuidString.lowercased())
        try mark(authority)
        let importArguments = [
            "import-initial-mac", archive.path, "--destination", authority.path,
            "--authority-database", "authority.sqlite", "--authority-assets", "blobs",
            "--library-id", binding.libraryID.uuidString,
            "--service-id", binding.serviceID.uuidString, "--import-id", UUID().uuidString,
        ]
        try migration(importArguments)
        try await host.start()
        let preparedPaths = StoragePaths(root: prepared)
        let preparedStore = try Store(paths: preparedPaths)
        await #expect(throws: SyncHTTPError.unauthorized) {
            try await StoreSyncImportHandoff(
                store: preparedStore, transport: transport(), credential: { "invalid-credential" })
        }
        let hasBindingAfterRefusal = try await preparedStore.reader.read {
            try $0.tableExists("sync_binding")
        }
        #expect(!hasBindingAfterRefusal)
        let handoff = try await StoreSyncImportHandoff(
            store: preparedStore, transport: transport(), credential: { token })
        let lost = LostApplyResponse(base: try transport())
        let operation: SyncOperation
        do {
            let attached = try Store(paths: preparedPaths, syncBinding: binding, imported: handoff)
            let client = try #require(attached.syncClient)
            #expect(try SearchService(store: attached).capture(id: 42) == original)
            try await client.pull(from: transport(), credential: { token })
            #expect(try client.cursor() == 1)
            #expect(try client.captures().count == 2)
            let imported = try #require(client.captures().first { $0.id == identity })
            #expect(imported.createdAt == now)
            #expect(imported.metadata?.updatedAt == original.updatedAt)
            #expect(imported.metadata?.lastSeenAt == original.lastSeenAt)
            #expect(imported.metadata?.reminderAt == original.reminderAt)
            #expect(imported.metadata?.sourceAppBundleID == original.sourceAppBundleID)
            #expect(imported.seenCount == 7)
            #expect(imported.rating == 5)
            #expect(imported.note == original.note)
            #expect(imported.manualTags == ["manual"])
            #expect(imported.generated.body == original.body)
            #expect(imported.generated.ocrText == original.ocrText)
            #expect(try client.blobs.read(#require(imported.source.blob)) == imageBytes)
            #expect(
                try client.captures().first { $0.source.title == "Generated HTTP source" }?
                    .generated.tags == ["generated"])
            _ = try attached.updateNote(
                id: 42, note: "HTTP client note", now: now.addingTimeInterval(200))
            operation = try #require(client.pendingOperations().first)
            #expect(operation.sequence == 1)
            #expect(operation.baseRevision == 1)
            await #expect(throws: SyncError.transportDisconnected) {
                try await client.push(to: lost, credential: { token })
            }
            #expect(try client.pendingOperations() == [operation])
        }
        let committed = try await AsyncHTTPActions(transport: transport(), credential: { token })
            .baseline()
        #expect(committed.cursor == 2)
        #expect(committed.captures.first { $0.id == identity }?.note == "HTTP client note")
        try host.stop()
        try migration(importArguments)
        try await host.start()
        let reopenedStore = try Store(
            paths: preparedPaths, syncBinding: binding, deviceID: deviceID)
        let reopened = try #require(reopenedStore.syncClient)
        #expect(try reopened.pendingOperations() == [operation])
        let retry = LostApplyResponse(base: try transport(), shouldDrop: false)
        let receipts = try await reopened.syncOnce(using: retry, credential: { token })
        #expect(receipts.first?.operationID == operation.id)
        #expect(try reopened.pendingOperations().isEmpty)
        #expect(await lost.applyBodies.first == retry.applyBodies.first)
        #expect(try reopened.cursor() == 2)
        #expect(try SearchService(store: reopenedStore).capture(id: 42)?.note == "HTTP client note")
        #expect(try SearchService(store: reopenedStore).search("pangolin").first?.capture.id == 42)
        #expect(try reopened.captures().first { $0.id == identity }?.seenCount == 7)
        let actions = AsyncHTTPActions(transport: try transport(), credential: { token })
        #expect(try await actions.changes(after: 1, limit: 100).changes.count == 1)
        let canonical = try #require(reopened.captures().first { $0.id == identity })
        var duplicate = SharedCapture(source: canonical.source, note: "Duplicate source note")
        duplicate.manualTags = ["phone"]
        let duplicateOperation = try reopened.enqueue(
            captureID: duplicate.id, mutation: .create(duplicate))
        let duplicateReceipts = try await reopened.syncOnce(
            using: transport(), credential: { token })
        #expect(duplicateOperation.sequence == 2)
        #expect(duplicateReceipts.first?.operationID == duplicateOperation.id)
        #expect(duplicateReceipts.first?.outcome == .noteConflict)
        #expect(duplicateReceipts.first?.capture?.id == identity)
        #expect(try reopened.captures().count == 2)
        let reconciled = try #require(reopened.captures().first { $0.id == identity })
        #expect(reconciled.seenCount == 8)
        #expect(reconciled.manualTags == ["manual", "phone"])
        #expect(
            Set(reconciled.noteConflicts.compactMap(\.value)) == [
                "HTTP client note", "Duplicate source note",
            ])
        try writeEnrollment(revoked: true)
        await #expect(throws: SyncHTTPError.unauthorized) {
            try await reopened.pull(from: transport(), credential: { token })
        }
        #expect(try reopened.cursor() == 3)
        #expect(try SearchService(store: store).capture(id: 42) == original)
        #expect(try SearchService(store: store).search("kestrel").first?.capture.id == 42)
        let sourceHasMapping = try await store.reader.read {
            try $0.tableExists("sync_capture_ids")
        }
        #expect(!sourceHasMapping)
        try host.stop()
        #expect(
            !(try String(contentsOf: root.appendingPathComponent("host.log"), encoding: .utf8))
                .contains(token))
    }

    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func mark(_ root: URL) throws {
        try Data("synthetic-capd-library-v1\n".utf8)
            .write(to: root.appendingPathComponent(".capd-synthetic-fixture"))
    }

    private func migration(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments =
            [repo.appendingPathComponent("Scripts/synthetic_library_migration.py").path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "MacHTTPImport", code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)
                ])
        }
    }
}

private actor LostApplyResponse: AsyncSyncTransport {
    nonisolated let binding: SyncLibraryBinding
    nonisolated let deviceID: UUID
    let base: URLSessionSyncTransport
    var shouldDrop: Bool
    var applyBodies: [Data] = []

    init(base: URLSessionSyncTransport, shouldDrop: Bool = true) {
        self.base = base
        self.binding = base.binding
        self.deviceID = base.deviceID
        self.shouldDrop = shouldDrop
    }

    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        let envelope = try JSONDecoder().decode(SyncHTTPEnvelope.self, from: request.body)
        let response = try await base.send(request)
        if case .apply = envelope.action {
            applyBodies.append(request.body)
            if shouldDrop {
                shouldDrop = false
                throw SyncError.transportDisconnected
            }
        }
        return response
    }
}

private final class IntegrationHTTPHost {
    let binary: URL
    let config: URL
    let data: URL
    let log: URL
    private var process: Process?
    private var output: FileHandle?
    private(set) var endpoint: URL?

    init(binary: URL, config: URL, data: URL, log: URL) {
        self.binary = binary
        self.config = config
        self.data = data
        self.log = log
    }

    func start() async throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NSError(
                domain: "MacHTTPImport", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Build Packages/CapdSyncServer before running this process integration test."
                ])
        }
        try Data().write(to: log)
        output = try FileHandle(forWritingTo: log)
        let child = Process()
        child.executableURL = binary
        child.arguments = ["--config", config.path, "--data-dir", data.path, "--port", "0"]
        child.standardOutput = output
        child.standardError = output
        try child.run()
        process = child
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while child.isRunning && ContinuousClock.now < deadline {
            let text = try String(contentsOf: log, encoding: .utf8)
            if let line = text.split(separator: "\n").first(where: {
                $0.hasPrefix("capd-sync-server ready ")
            }),
                let address = line.split(separator: " ").last,
                let url = URL(string: "http://\(address)/v1/sync")
            {
                endpoint = url
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(
            domain: "MacHTTPImport", code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "Standalone synthetic HTTP host failed to become ready."
            ])
    }

    func stop() throws {
        guard let process else { return }
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard !process.isRunning else { throw NSError(domain: "MacHTTPImport", code: 3) }
        self.process = nil
        endpoint = nil
        try output?.close()
        output = nil
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "MacHTTPImport", code: Int(process.terminationStatus))
        }
    }
}
