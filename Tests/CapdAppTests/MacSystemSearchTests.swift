import CapdSystemIntegration
import Foundation
import Testing

@testable import CapdApp
@testable import CapdAppUI
@testable import CapdKit

@MainActor
@Suite(.serialized)
struct MacSystemSearchTests {
    @Test func freshReadOnlyQueriesRouteAndDeleteWithoutCapturing() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "capd-discovery-\(UUID())")
        let suite = "capd-discovery-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let paths = StoragePaths(root: root)
        let store = try MacLibrarySession.open(paths: paths).store
        let outcome = try CaptureService(store: store).ingest(
            CaptureRequest(
                text: "Private body token", title: "Synthetic kestrel", note: "Hidden note token",
                tags: ["manual"]))
        let backend = DiscoveryMemoryIndex()
        var actions: [(CaptureAction, Int64?)] = []
        let host = MacSystemSearch(
            paths: paths, enabled: false, defaults: defaults, backend: backend
        ) {
            actions.append(($0, $1))
        }
        let runtime = CaptureIntentRuntime()
        runtime.host = host
        #expect(throws: SystemIntegrationError.privacyDisabled) { try runtime.search("kestrel") }
        #expect(backend.items.isEmpty)
        host.setEnabled(true)
        await host.settle()
        let entry = try #require(try runtime.search("kestrel").first)
        #expect(entry.text.isEmpty)
        #expect(entry.keywords == ["manual"])
        #expect(try runtime.search("Hidden").isEmpty)
        #expect(try runtime.search("Private").isEmpty)
        try runtime.perform(.open(entry.reference))
        #expect(actions.last?.1 == outcome.capture.id)
        try runtime.perform(.stageText("Synthetic unsaved draft"))
        #expect(try SearchService(store: store).totalCaptureCount() == 1)
        _ = try store.deleteCaptures(ids: [try #require(outcome.capture.id)])
        #expect(try runtime.resolve([entry.reference]).isEmpty)
        #expect(throws: SystemIntegrationError.missingCapture) {
            try runtime.perform(.open(entry.reference))
        }
        host.refresh()
        await host.settle()
        #expect(backend.items.isEmpty)
        host.setEnabled(false)
        #expect(throws: SystemIntegrationError.privacyDisabled) { try runtime.search("") }
        await host.settle()
    }

    @Test func unchangedPollsSkipSnapshotsAndOtherWritersInvalidateTheIndex() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "capd-discovery-refresh-\(UUID())")
        let suite = "capd-discovery-refresh-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let paths = StoragePaths(root: root)
        let store = try MacLibrarySession.open(paths: paths).store
        _ = try CaptureService(store: store).ingest(CaptureRequest(text: "First", title: "First"))
        let backend = DiscoveryMemoryIndex()
        var loads = 0
        var failNextLoad = false
        var issue: String?
        let host = MacSystemSearch(
            paths: paths, enabled: true, defaults: defaults, backend: backend,
            loadSnapshot: { paths, localID in
                loads += 1
                if failNextLoad {
                    failNextLoad = false
                    throw DiscoveryTestError.injected
                }
                return try MacDiscoverySnapshot.load(paths: paths, localLibraryID: localID)
            }, dispatch: { _, _ in })
        host.reportIssue = { issue = $0 }
        host.refresh()
        await host.settle()
        #expect(loads == 1)
        for _ in 0..<20 { host.refresh() }
        await host.settle()
        #expect(loads == 1)
        #expect(backend.items.count == 1)
        let otherWriter = try MacLibrarySession.open(paths: paths).store
        _ = try CaptureService(store: otherWriter).ingest(
            CaptureRequest(text: "Second", title: "Second"))
        failNextLoad = true
        host.refresh()
        await host.settle()
        #expect(loads == 2)
        #expect(issue != nil)
        #expect(backend.items.isEmpty)
        host.refresh()
        await host.settle()
        #expect(loads == 3)
        #expect(issue == nil)
        #expect(backend.items.count == 2)
        host.refresh()
        await host.settle()
        #expect(loads == 3)
        host.setEnabled(false)
        await host.settle()
        #expect(backend.items.isEmpty)
        host.setEnabled(true)
        await host.settle()
        #expect(loads == 4)
        #expect(backend.items.count == 2)
        try Data("invalid configuration".utf8).write(to: MacSyncConfiguration.url(paths: paths))
        host.refresh()
        await host.settle()
        #expect(loads == 5)
        #expect(issue != nil)
        #expect(backend.items.isEmpty)
    }

    @Test func identifierBatchResolvesFromOneSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "capd-discovery-batch-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let paths = StoragePaths(root: root)
        let store = try MacLibrarySession.open(paths: paths).store
        for index in 0..<100 {
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(text: "Batch \(index)", title: "Capture \(index)"))
        }
        var loads = 0
        let host = MacSystemSearch(
            paths: paths, enabled: true, defaults: defaults,
            backend: DiscoveryMemoryIndex(),
            loadSnapshot: { paths, localID in
                loads += 1
                return try MacDiscoverySnapshot.load(paths: paths, localLibraryID: localID)
            }, dispatch: { _, _ in })
        let runtime = CaptureIntentRuntime()
        runtime.host = host
        let records = try host.search("")
        loads = 0
        let references = records.reversed().map(\.reference)
        #expect(try runtime.resolve(references).map(\.reference) == references)
        #expect(loads == 1)
        loads = 0
        let mixed = [
            references[0], references[0], CaptureReference(libraryID: UUID(), captureID: UUID()),
        ]
        #expect(try runtime.resolve(mixed).map(\.reference) == [references[0]])
        #expect(loads == 1)
        loads = 0
        #expect(try runtime.resolve([]).isEmpty)
        #expect(loads == 0)
        #expect(throws: SystemIntegrationError.invalidInput) {
            try runtime.resolve(references + [references[0]])
        }
        #expect(loads == 0)
        host.setEnabled(false)
        #expect(throws: SystemIntegrationError.privacyDisabled) { try runtime.resolve(references) }
        #expect(loads == 0)
        await host.settle()
    }

    @Test(arguments: [false, true])
    func recreatedDatabaseAtSamePathInvalidatesSavedReferences(atomicReplacement: Bool) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "capd-discovery-replacement-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let paths = StoragePaths(root: root)
        do {
            let store = try MacLibrarySession.open(paths: paths).store
            _ = try CaptureService(store: store).ingest(CaptureRequest(text: "Old", title: "Old"))
            try store.dbPool.close()
        }
        let backend = DiscoveryMemoryIndex()
        var opened: [Int64] = []
        let host = MacSystemSearch(
            paths: paths, enabled: true, defaults: defaults,
            backend: backend, dispatch: { _, id in if let id { opened.append(id) } })
        let saved = try #require(try host.search("").first)
        let reopened = MacSystemSearch(
            paths: paths, enabled: true, defaults: defaults,
            backend: backend, dispatch: { _, _ in })
        #expect(try reopened.resolve(saved.reference) == saved)
        host.refresh()
        await host.settle()
        if atomicReplacement {
            let replacement = StoragePaths(root: root.appendingPathComponent("replacement"))
            let store = try MacLibrarySession.open(paths: replacement).store
            _ = try CaptureService(store: store).ingest(CaptureRequest(text: "New", title: "New"))
            try store.dbPool.close()
            _ = try FileManager.default.replaceItemAt(
                paths.databaseURL,
                withItemAt: replacement.databaseURL)
        } else {
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: paths.databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
            }
            let store = try MacLibrarySession.open(paths: paths).store
            _ = try CaptureService(store: store).ingest(CaptureRequest(text: "New", title: "New"))
            try store.dbPool.close()
        }
        let current = try #require(try host.search("").first)
        #expect(current.reference.libraryID != saved.reference.libraryID)
        #expect(current.reference != saved.reference)
        let runtime = CaptureIntentRuntime()
        runtime.host = host
        #expect(try runtime.resolve([saved.reference]).isEmpty)
        #expect(throws: SystemIntegrationError.missingCapture) {
            try runtime.perform(.open(saved.reference))
        }
        #expect(opened.isEmpty)
        try runtime.perform(.open(current.reference))
        #expect(opened == [1])
        let restarted = MacSystemSearch(
            paths: paths, enabled: true, defaults: defaults,
            backend: backend, dispatch: { _, _ in })
        #expect(try restarted.resolve(current.reference) == current)
        host.refresh()
        await host.settle()
        #expect(Set(backend.items.keys) == [current.id])
    }

    @Test func replacedSymlinkTargetInvalidatesReferencesAndRefreshesIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "capd-discovery-symlink-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let paths = StoragePaths(root: root.appendingPathComponent("link"))
        let target = StoragePaths(root: root.appendingPathComponent("target"))
        try paths.createDirectories()
        do {
            let store = try MacLibrarySession.open(paths: target).store
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(text: "Old target", title: "Old target"))
            try store.dbPool.close()
        }
        try FileManager.default.createSymbolicLink(
            at: paths.databaseURL,
            withDestinationURL: target.databaseURL)
        let backend = DiscoveryMemoryIndex()
        var opened: [Int64] = []
        let host = MacSystemSearch(
            paths: paths, enabled: true, defaults: defaults,
            backend: backend, dispatch: { _, id in if let id { opened.append(id) } })
        let saved = try #require(try host.search("").first)
        let replacement = StoragePaths(root: root.appendingPathComponent("replacement"))
        do {
            let store = try MacLibrarySession.open(paths: replacement).store
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(text: "New target", title: "New target"))
            try store.dbPool.close()
        }
        for suffix in ["", "-wal", "-shm"] {
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: target.databaseURL.path + suffix),
                withItemAt: URL(fileURLWithPath: replacement.databaseURL.path + suffix))
        }
        let current = try #require(try host.search("").first)
        #expect(current.reference.libraryID != saved.reference.libraryID)
        #expect(current.title == "New target")
        let runtime = CaptureIntentRuntime()
        runtime.host = host
        #expect(try runtime.resolve([saved.reference]).isEmpty)
        #expect(throws: SystemIntegrationError.missingCapture) {
            try runtime.perform(.open(saved.reference))
        }
        #expect(opened.isEmpty)
        try runtime.perform(.open(current.reference))
        #expect(opened == [1])
        host.refresh()
        await host.settle()
        #expect(Set(backend.items.keys) == [current.id])
        #expect(backend.items[current.id]?.title == "New target")
    }

    @Test func legacyPathIdentityRotatesOnceWithoutWritingTheStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "capd-discovery-legacy-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let paths = StoragePaths(root: root)
        do {
            let store = try MacLibrarySession.open(paths: paths).store
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(text: "Synthetic", title: "Synthetic"))
            try store.dbPool.close()
        }
        let legacyID = UUID()
        defaults.set(
            legacyID.uuidString, forKey: "capd.system-search.local-id." + paths.databaseURL.path)
        let prior = try MacDiscoverySnapshot.load(paths: paths, localLibraryID: legacyID)
        let old = CaptureReference(
            libraryID: legacyID, captureID: try #require(prior.captures.first?.id))
        let before = try Data(contentsOf: paths.databaseURL)
        let backend = DiscoveryMemoryIndex()
        let host = MacSystemSearch(
            paths: paths, enabled: true, defaults: defaults,
            backend: backend, dispatch: { _, _ in })
        let current = try #require(try host.search("").first)
        #expect(current.reference.libraryID != legacyID)
        #expect(try host.resolve(old) == nil)
        let restarted = MacSystemSearch(
            paths: paths, enabled: true, defaults: defaults,
            backend: backend, dispatch: { _, _ in })
        #expect(try restarted.resolve(current.reference) == current)
        #expect(try Data(contentsOf: paths.databaseURL) == before)
    }

    @Test func exactSourcePresentationWinsOverInFlightQuery() async throws {
        let selected = Capture(
            kind: .text, title: "Selected source", selection: "synthetic", createdAt: Date())
        let model = SearchModel(
            environment: SearchEnvironment(
                search: { _ in
                    try await Task.sleep(for: .milliseconds(20))
                    return []
                }, totalCount: { 0 }, delete: { _ in }, openURL: { _ in }, copyText: { _ in },
                assetFileURL: { _ in nil }, showHUD: { _ in }))
        model.activate()
        model.presentCapture(selected)
        await model.settle()
        #expect(model.hits.map(\.capture) == [selected])
        #expect(model.hasLoaded)
    }
}

@MainActor
private final class DiscoveryMemoryIndex: SpotlightBackend {
    var items: [String: SearchCapture] = [:]
    func replace(_ captures: [SearchCapture], domain: String) async throws {
        for capture in captures { items[capture.id] = capture }
    }
    func delete(identifiers: [String]) async throws {
        for id in identifiers { items.removeValue(forKey: id) }
    }
    func delete(domain: String) async throws { items.removeAll() }
}

private enum DiscoveryTestError: Error { case injected }
