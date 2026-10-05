import CapdSystemIntegration
import Foundation
import Testing

@testable import CapdApp
@testable import CapdKit

@MainActor
struct MacSystemSearchStartupTests {
    @Test func runningCleanupRetriesAndReportsUntilScopedDeletionSucceeds() async throws {
        let paths = StoragePaths(
            root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let suite = "capd-search-running-cleanup-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "capd.system-search.indexed-id." + paths.databaseURL.path
        let libraryID = UUID()
        let backend = StartupMemoryIndex()
        let domain = SpotlightCoordinator(libraryID: libraryID, backend: backend).domain
        defaults.set(libraryID.uuidString, forKey: key)
        backend.domains = [domain, "unrelated-domain"]
        backend.fail = true
        var waits = 0
        var issues: [String?] = []
        await MacSystemSearchCleanup.run(
            remove: {
                try await MacSystemSearch.removePersistedIndex(
                    paths: paths, defaults: defaults, backend: backend)
            },
            reportIssue: { issues.append($0) },
            waitToRetry: {
                #expect(defaults.string(forKey: key) == libraryID.uuidString)
                #expect(backend.domains == [domain, "unrelated-domain"])
                waits += 1
                if waits == 2 { backend.fail = false }
            })
        #expect(waits == 2)
        #expect(issues.count == 3)
        #expect(issues.prefix(2).allSatisfy { $0 != nil })
        #expect(issues.last == .some(nil))
        #expect(defaults.string(forKey: key) == nil)
        #expect(backend.domains == ["unrelated-domain"])
        #expect(!FileManager.default.fileExists(atPath: paths.databaseURL.path))
    }

    @Test func cancelledRetryKeepsFailureAndStopsCleanup() async {
        var attempts = 0
        var issues: [String?] = []
        await MacSystemSearchCleanup.run(
            remove: {
                attempts += 1
                throw StartupMemoryIndex.Failure.injected
            },
            reportIssue: { issues.append($0) },
            waitToRetry: { throw CancellationError() })
        #expect(attempts == 1)
        #expect(issues.count == 1)
        #expect(issues.first == .some(StartupMemoryIndex.Failure.injected.localizedDescription))
    }

    @Test func failedStoreOpenDeletesOnlyPersistedLibraryDomain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = StoragePaths(root: root)
        try paths.createDirectories()
        try Data("Synthetic corrupt database".utf8).write(to: paths.databaseURL)
        let suite = "capd-search-failure-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let libraryID = UUID()
        let backend = StartupMemoryIndex()
        let domain = SpotlightCoordinator(libraryID: libraryID, backend: backend).domain
        backend.domains = [domain, "unrelated-domain"]
        let key = "capd.system-search.indexed-id." + paths.databaseURL.path
        defaults.set(libraryID.uuidString, forKey: key)
        #expect(throws: (any Error).self) { try MacLibrarySession.open(paths: paths) }
        try await MacSystemSearch.removePersistedIndex(
            paths: paths, defaults: defaults, backend: backend)
        #expect(backend.domains == ["unrelated-domain"])
        #expect(defaults.string(forKey: key) == nil)
        #expect(try Data(contentsOf: paths.databaseURL) == Data("Synthetic corrupt database".utf8))
    }

    @Test func failedCleanupRetainsScopeForNextRetry() async throws {
        let paths = StoragePaths(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
        let suite = "capd-search-cleanup-retry-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "capd.system-search.indexed-id." + paths.databaseURL.path
        let libraryID = UUID()
        defaults.set(libraryID.uuidString, forKey: key)
        let backend = StartupMemoryIndex()
        backend.fail = true
        await #expect(throws: StartupMemoryIndex.Failure.self) {
            try await MacSystemSearch.removePersistedIndex(
                paths: paths, defaults: defaults, backend: backend)
        }
        #expect(defaults.string(forKey: key) == libraryID.uuidString)
        backend.fail = false
        try await MacSystemSearch.removePersistedIndex(
            paths: paths, defaults: defaults, backend: backend)
        #expect(defaults.string(forKey: key) == nil)
    }
}

@MainActor
private final class StartupMemoryIndex: SpotlightBackend {
    enum Failure: Error { case injected }
    var domains: Set<String> = []
    var fail = false
    func replace(_ captures: [SearchCapture], domain: String) async throws {}
    func delete(identifiers: [String]) async throws {}
    func delete(domain: String) async throws {
        if fail { throw Failure.injected }
        domains.remove(domain)
    }
}
