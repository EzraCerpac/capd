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
