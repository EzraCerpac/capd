import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdKit

@Suite("CLI bound Mac runtime", .timeLimit(.minutes(1)))
struct CLISyncRuntimeTests {
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
