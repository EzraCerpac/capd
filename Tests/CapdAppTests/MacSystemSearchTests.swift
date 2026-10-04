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
