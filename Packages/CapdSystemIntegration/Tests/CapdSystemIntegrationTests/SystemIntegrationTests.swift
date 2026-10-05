import AppIntents
import CoreSpotlight
import Foundation
import Testing

@testable import CapdSystemIntegration

private let library = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let captureID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private let reference = CaptureReference(libraryID: library, captureID: captureID)
private func fixture(
    revision: Int64 = 0, text: String = "synthetic indigo notebook", deleted: Bool = false
) -> SearchCapture {
    SearchCapture(
        reference: reference, title: "Synthetic capture", text: text, revision: revision,
        deleted: deleted)
}

@MainActor
private final class MemoryIndex: SpotlightBackend {
    var items: [String: SearchCapture] = [:]
    var domains: [String: String] = [:]
    var calls: [String] = []
    var batches: [[String]] = []
    var failReplace = false
    var partiallyAcceptReplace = false
    var pauseReplace = false
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func replace(_ captures: [SearchCapture], domain: String) async throws {
        calls.append("replace")
        batches.append(captures.map(\.id))
        started = true
        if pauseReplace { await withCheckedContinuation { continuation = $0 } }
        if partiallyAcceptReplace, let first = captures.first {
            items[first.id] = first
            domains[first.id] = domain
            throw SystemIntegrationError.unavailable
        }
        if failReplace { throw SystemIntegrationError.unavailable }
        for capture in captures {
            items[capture.id] = capture
            domains[capture.id] = domain
        }
    }
    func delete(identifiers: [String]) async throws {
        calls.append("deleteIDs")
        for id in identifiers {
            items.removeValue(forKey: id)
            domains.removeValue(forKey: id)
        }
    }
    func delete(domain: String) async throws {
        calls.append("deleteDomain")
        for id in domains.filter({ $0.value == domain }).keys {
            items.removeValue(forKey: id)
            domains.removeValue(forKey: id)
        }
    }
}

@MainActor
private final class IndexClock {
    var date = Date(timeIntervalSinceReferenceDate: 10_000)
}

struct CaptureRouteTests {
    @Test func stableIdentityAndRouteRoundTrip() throws {
        #expect(CaptureReference(identifier: reference.id) == reference)
        #expect(CaptureReference(identifier: reference.id.uppercased()) == nil)
        #expect(CaptureRoute(url: CaptureRoute.open(reference).url) == .open(reference))
        let query = "Café & sketches? #草 + / %"
        #expect(CaptureRoute(url: CaptureRoute.find(query).url) == .find(query))
        #expect(CaptureReference(libraryID: UUID(), captureID: captureID).id != reference.id)
        #expect(CaptureReference(libraryID: library, captureID: captureID).id == reference.id)
    }

    @Test func untrustedRoutesAreRejected() {
        for value in [
            "https://open?library=\(library)&id=\(captureID)",
            "capd://user@open?library=\(library)&id=\(captureID)",
            "capd://open:80?library=\(library)&id=\(captureID)",
            "capd://open/extra?library=\(library)&id=\(captureID)",
            "capd://open?library=\(library)&id=\(captureID)#fragment",
            "capd://open?library=\(library)&id=1",
            "capd://open?library=\(library)&id=\(captureID)&id=\(captureID)",
            "capd://open?library=\(library)&id=\(captureID)&save=true",
            "capd://capture-text?text=unauthorized", "capd://find?q=x&q=y",
            "capd://find?q", "capd://find?q=\(String(repeating: "x", count: 513))",
        ] {
            #expect(CaptureRoute(url: URL(string: value)!) == nil)
        }
    }

    @Test @MainActor func spotlightAttributesAndActivity() {
        let before = Date().addingTimeInterval(30 * 24 * 60 * 60)
        let item = CoreSpotlightBackend.item(fixture(), domain: "synthetic.test")
        let after = Date().addingTimeInterval(30 * 24 * 60 * 60)
        #expect(item.uniqueIdentifier == reference.id)
        #expect(item.domainIdentifier == "synthetic.test")
        #expect(item.attributeSet.title == "Synthetic capture")
        #expect(item.attributeSet.textContent == "synthetic indigo notebook")
        #expect(item.attributeSet.contentURL == CaptureRoute.open(reference).url)
        #expect(item.expirationDate >= before && item.expirationDate <= after)
        let date = Date(timeIntervalSinceReferenceDate: 10_000)
        #expect(
            CoreSpotlightBackend.item(fixture(), domain: "synthetic.test", now: date).expirationDate
                == date.addingTimeInterval(30 * 24 * 60 * 60))
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: reference.id]
        #expect(CaptureRoute(spotlightActivity: activity) == .open(reference))
        activity.userInfo = [CSSearchableItemActivityIdentifier: "42"]
        #expect(CaptureRoute(spotlightActivity: activity) == nil)
    }
}

@MainActor
struct SpotlightCoordinatorTests {
    @Test func unchangedEntriesRenewIndependentlyAfterOneDay() async throws {
        let clock = IndexClock()
        let backend = MemoryIndex()
        let coordinator = SpotlightCoordinator(
            libraryID: library, backend: backend, now: { clock.date })
        let first = fixture()
        var second = SearchCapture(
            reference: CaptureReference(libraryID: library, captureID: UUID()), title: "Second")
        try await coordinator.reconcile([first, second], enabled: true)
        clock.date += 12 * 60 * 60
        second.revision += 1
        try await coordinator.reconcile([first, second], enabled: true)
        #expect(backend.batches.last == [second.id])
        clock.date += 12 * 60 * 60 - 1
        #expect(!coordinator.needsRenewal)
        try await coordinator.reconcile([first, second], enabled: true)
        #expect(backend.batches.count == 2)
        clock.date += 1
        #expect(coordinator.needsRenewal)
        try await coordinator.reconcile([first, second], enabled: true)
        #expect(backend.batches.last == [first.id])
        #expect(!coordinator.needsRenewal)
        clock.date += 12 * 60 * 60
        try await coordinator.reconcile([first, second], enabled: true)
        #expect(backend.batches.last == [second.id])
        clock.date -= 48 * 60 * 60
        #expect(coordinator.needsRenewal)
    }

    @Test func failedRenewalRemainsDueAndRetriesFromACleanDomain() async throws {
        let clock = IndexClock()
        let backend = MemoryIndex()
        let coordinator = SpotlightCoordinator(
            libraryID: library, backend: backend, now: { clock.date })
        try await coordinator.reconcile([fixture()], enabled: true)
        clock.date += 24 * 60 * 60
        backend.failReplace = true
        await #expect(throws: SystemIntegrationError.unavailable) {
            try await coordinator.reconcile([fixture()], enabled: true)
        }
        #expect(coordinator.needsRenewal)
        backend.failReplace = false
        try await coordinator.reconcile([fixture()], enabled: true)
        #expect(backend.calls.filter { $0 == "deleteDomain" }.count == 2)
        #expect(!coordinator.needsRenewal)
    }

    @Test func renewalCannotReviveRemovedItemsOrBypassSnapshotValidation() async throws {
        let clock = IndexClock()
        let backend = MemoryIndex()
        let coordinator = SpotlightCoordinator(
            libraryID: library, backend: backend, now: { clock.date })
        let other = SearchCapture(
            reference: CaptureReference(libraryID: library, captureID: UUID()), title: "Other")
        try await coordinator.reconcile([fixture(), other], enabled: true)
        clock.date += 24 * 60 * 60
        let calls = backend.calls
        await #expect(throws: SystemIntegrationError.invalidSnapshot) {
            try await coordinator.reconcile(
                [fixture(), fixture(text: "invalid duplicate")], enabled: true)
        }
        #expect(backend.calls == calls)
        #expect(coordinator.needsRenewal)
        try await coordinator.reconcile([fixture(deleted: true), other], enabled: true)
        #expect(backend.batches.last == [other.id])
        #expect(backend.items[reference.id] == nil)
        try await coordinator.reconcile([], enabled: false)
        clock.date += 40 * 24 * 60 * 60
        #expect(!coordinator.needsRenewal)
        #expect(backend.items.isEmpty)
        let cold = SpotlightCoordinator(libraryID: library, backend: backend, now: { clock.date })
        try await cold.reconcile([other], enabled: true)
        #expect(backend.calls.suffix(2) == ["deleteDomain", "replace"])
        #expect(!cold.needsRenewal)
    }

    @Test func updatesDedupesAndDeletes() async throws {
        let backend = MemoryIndex()
        let coordinator = SpotlightCoordinator(
            libraryID: library, namespace: "synthetic.tests", backend: backend)
        try await coordinator.reconcile([fixture(), fixture()], enabled: true)
        #expect(backend.items.count == 1)
        #expect(backend.calls == ["deleteDomain", "replace"])
        try await coordinator.reconcile([fixture()], enabled: true)
        #expect(backend.calls.count == 2)
        try await coordinator.reconcile(
            [fixture(), fixture(revision: 1, text: "updated synthetic")], enabled: true)
        #expect(backend.items[reference.id]?.text == "updated synthetic")
        try await coordinator.reconcile(
            [fixture(revision: 1), fixture(revision: 1, deleted: true)], enabled: true)
        #expect(backend.items.isEmpty)
        #expect(backend.calls.last == "deleteIDs")
        try await coordinator.reconcile([fixture(revision: 2)], enabled: true)
        try await coordinator.reconcile([], enabled: true)
        #expect(backend.items.isEmpty)
    }

    @Test func canonicalAliasReplacementLeavesOneCrossDeviceItem() async throws {
        let backend = MemoryIndex()
        let coordinator = SpotlightCoordinator(libraryID: library, backend: backend)
        let alias = SearchCapture(
            reference: CaptureReference(libraryID: library, captureID: UUID()),
            title: "Synthetic duplicate", text: "same synthetic content")
        try await coordinator.reconcile([alias], enabled: true)
        try await coordinator.reconcile([fixture(), fixture()], enabled: true)
        #expect(Set(backend.items.keys) == [reference.id])
        #expect(backend.calls.contains("deleteIDs"))
        try await coordinator.reconcile([fixture(deleted: true)], enabled: true)
        #expect(backend.items.isEmpty)
    }

    @Test func startupAndConsentRemovalStayScoped() async throws {
        let backend = MemoryIndex()
        let coordinator = SpotlightCoordinator(
            libraryID: library, namespace: "synthetic.tests", backend: backend)
        backend.items["unrelated"] = fixture()
        backend.domains["unrelated"] = "another-app"
        backend.items[reference.id] = fixture()
        backend.domains[reference.id] = coordinator.domain
        try await coordinator.reconcile([], enabled: false)
        #expect(Set(backend.items.keys) == ["unrelated"])
        try await coordinator.reconcile([fixture()], enabled: true)
        try await coordinator.reconcile([fixture()], enabled: false)
        #expect(Set(backend.items.keys) == ["unrelated"])
    }

    @Test func invalidSnapshotsDoNotMutateIndex() async throws {
        let backend = MemoryIndex()
        let coordinator = SpotlightCoordinator(libraryID: library, backend: backend)
        await #expect(throws: SystemIntegrationError.snapshotTooLarge) {
            try await coordinator.reconcile(Array(repeating: fixture(), count: 1001), enabled: true)
        }
        var wrongLibrary = fixture()
        wrongLibrary = SearchCapture(
            reference: CaptureReference(libraryID: UUID(), captureID: captureID), title: "synthetic"
        )
        await #expect(throws: SystemIntegrationError.invalidSnapshot) {
            try await coordinator.reconcile([wrongLibrary], enabled: true)
        }
        await #expect(throws: SystemIntegrationError.invalidSnapshot) {
            try await coordinator.reconcile(
                [fixture(), fixture(text: "conflicting same revision")], enabled: true)
        }
        var oversized = fixture()
        oversized.text = String(repeating: "x", count: 8193)
        let decoded = try JSONDecoder().decode(
            SearchCapture.self, from: JSONEncoder().encode(oversized))
        await #expect(throws: SystemIntegrationError.invalidSnapshot) {
            try await coordinator.reconcile([decoded], enabled: true)
        }
        #expect(backend.calls.isEmpty)
    }

    @Test func failedIndexingRetriesAndCancellationDoesNotDonate() async throws {
        let backend = MemoryIndex()
        let coordinator = SpotlightCoordinator(libraryID: library, backend: backend)
        backend.failReplace = true
        await #expect(throws: SystemIntegrationError.unavailable) {
            try await coordinator.reconcile([fixture()], enabled: true)
        }
        backend.failReplace = false
        try await coordinator.reconcile([fixture()], enabled: true)
        #expect(backend.items.count == 1)
        let task = Task { @MainActor in
            try await coordinator.reconcile([fixture(revision: 2)], enabled: true)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(backend.items[reference.id]?.revision == 0)
    }

    @Test func partiallyAcceptedFailedBatchIsRemovedByNextReconciliation() async throws {
        let backend = MemoryIndex()
        let coordinator = SpotlightCoordinator(libraryID: library, backend: backend)
        let initial = fixture()
        let partial = SearchCapture(
            reference: CaptureReference(libraryID: library, captureID: UUID()),
            title: "Partially accepted capture")
        let survivor = SearchCapture(
            reference: CaptureReference(libraryID: library, captureID: UUID()),
            title: "Current capture")
        backend.items["unrelated"] = fixture()
        backend.domains["unrelated"] = "another-app"
        try await coordinator.reconcile([initial], enabled: true)
        backend.partiallyAcceptReplace = true
        await #expect(throws: SystemIntegrationError.unavailable) {
            try await coordinator.reconcile([initial, partial], enabled: true)
        }
        #expect(backend.items[partial.id] == partial)
        backend.partiallyAcceptReplace = false
        try await coordinator.reconcile([survivor], enabled: true)
        #expect(Set(backend.items.keys) == ["unrelated", survivor.id])
        #expect(backend.calls.filter { $0 == "deleteDomain" }.count == 2)
        #expect(backend.domains["unrelated"] == "another-app")
    }

    @Test func revocationDuringIndexingIsSerializedAndUncancellable() async throws {
        let backend = MemoryIndex()
        backend.pauseReplace = true
        let coordinator = SpotlightCoordinator(libraryID: library, backend: backend)
        let indexing = Task { @MainActor in
            try await coordinator.reconcile([fixture()], enabled: true)
        }
        while !backend.started { await Task.yield() }
        let revoke = Task { @MainActor in try await coordinator.reconcile([], enabled: false) }
        await Task.yield()
        revoke.cancel()
        backend.continuation?.resume()
        try await indexing.value
        try await revoke.value
        #expect(backend.items.isEmpty)
        #expect(backend.calls == ["deleteDomain", "replace", "deleteDomain"])
    }
}

@MainActor
@Suite(.serialized)
struct IntentHostTests {
    @Test func coldIntentsAndEntityQueriesAwaitHostPreparation() async throws {
        let runtime = CaptureIntentRuntime.shared
        let previous = runtime.host
        defer { runtime.host = previous }
        let preparation = HeldIntentPreparation()
        let host = CaptureSystemBridge(preparingForIntent: { await preparation.wait() })
        host.install()
        let find = FindCapturesIntent()
        find.query = "indigo"
        let finding = Task { @MainActor in _ = try await find.perform() }
        let resolving = Task { @MainActor in
            try await CaptureEntityQuery().entities(for: [reference.id])
        }
        for _ in 0..<100 where preparation.waiters.count < 2 { await Task.yield() }
        #expect(preparation.waiters.count == 2)
        #expect(host.pendingAction == nil)
        try host.refresh(libraryID: library, captures: [fixture()], systemSearchEnabled: true)
        preparation.finish()
        try await finding.value
        #expect(try await resolving.value.map(\.id) == [reference.id])
        #expect(host.consumeAction() == .find("indigo"))
        let open = OpenCaptureIntent()
        open.capture = CaptureEntity(fixture())
        _ = try await open.perform()
        #expect(host.consumeAction() == .open(reference))
        host.invalidate()
        await #expect(throws: SystemIntegrationError.privacyDisabled) {
            _ = try await find.perform()
        }
        #expect(host.pendingAction == nil)
    }

    @Test func failedHostPreparationHasNoIntentSideEffects() async throws {
        let runtime = CaptureIntentRuntime.shared
        let previous = runtime.host
        defer { runtime.host = previous }
        let host = CaptureSystemBridge(preparingForIntent: {
            throw SystemIntegrationError.unavailable
        })
        host.install()
        let find = FindCapturesIntent()
        find.query = "indigo"
        await #expect(throws: SystemIntegrationError.unavailable) { _ = try await find.perform() }
        #expect(host.pendingAction == nil)
    }

    @Test func coldRouteWaitsForSnapshotAndHonorsConsent() throws {
        let previous = CaptureIntentRuntime.shared.host
        defer { CaptureIntentRuntime.shared.host = previous }
        let host = CaptureSystemBridge()
        host.install()
        host.receive(.open(reference))
        #expect(host.pendingAction == nil)
        host.invalidate(preservingDeferredRoute: true)
        try host.refresh(libraryID: library, captures: [fixture()], systemSearchEnabled: true)
        #expect(host.consumeAction() == .open(reference))
        host.invalidate()
        host.receive(.find("indigo"))
        try host.refresh(libraryID: library, captures: [], systemSearchEnabled: false)
        #expect(host.pendingAction == nil)
        #expect(host.routingError == SystemIntegrationError.privacyDisabled.localizedDescription)
    }

    @Test func unavailablePrivacyAndFreshResolution() throws {
        let runtime = CaptureIntentRuntime()
        #expect(throws: SystemIntegrationError.unavailable) { try runtime.perform(.find("indigo")) }
        let host = CaptureSystemBridge()
        runtime.host = host
        #expect(throws: SystemIntegrationError.privacyDisabled) { try runtime.search("indigo") }
        #expect(throws: SystemIntegrationError.privacyDisabled) {
            try runtime.perform(.find("indigo"))
        }
        #expect(throws: SystemIntegrationError.privacyDisabled) {
            try runtime.perform(.open(reference))
        }
        try host.refresh(libraryID: library, captures: [fixture()], systemSearchEnabled: true)
        #expect(try runtime.search("indigo").map(\.id) == [reference.id])
        #expect(try runtime.search("no match").isEmpty)
        #expect(try runtime.resolve([reference, reference]).count == 1)
        try runtime.perform(.open(reference))
        #expect(host.consumeAction() == .open(reference))
        #expect(host.consumeAction() == nil)
        try host.refresh(
            libraryID: library, captures: [fixture(deleted: true)], systemSearchEnabled: true)
        #expect(try runtime.resolve([reference]).isEmpty)
        #expect(throws: SystemIntegrationError.missingCapture) {
            try runtime.perform(.open(reference))
        }
        #expect(throws: SystemIntegrationError.missingCapture) {
            try runtime.perform(.open(CaptureReference(libraryID: UUID(), captureID: captureID)))
        }
    }

    @Test func textOnlyStagesAndInvalidInputHasNoAction() async throws {
        let runtime = CaptureIntentRuntime()
        let host = CaptureSystemBridge()
        runtime.host = host
        #expect(throws: SystemIntegrationError.invalidInput) {
            try runtime.perform(.stageText(" \n"))
        }
        #expect(throws: SystemIntegrationError.invalidInput) {
            try runtime.perform(.stageText(String(repeating: "x", count: 8193)))
        }
        #expect(host.pendingAction == nil)
        try runtime.perform(.stageText("explicit synthetic text"))
        #expect(host.consumeAction() == .stageText("explicit synthetic text"))
        let index = SpotlightCoordinator(libraryID: library, backend: MemoryIndex())
        try await host.deactivate(using: index)
        #expect(host.pendingAction == nil)
    }

    @Test func hostDeactivationRemovesOnlyItsLibraryIndex() async throws {
        let runtime = CaptureIntentRuntime()
        let host = CaptureSystemBridge()
        runtime.host = host
        try host.refresh(libraryID: library, captures: [fixture()], systemSearchEnabled: true)
        let backend = MemoryIndex()
        let index = SpotlightCoordinator(
            libraryID: library, namespace: "synthetic.tests", backend: backend)
        try await index.reconcile([fixture()], enabled: true)
        backend.items["other"] = fixture()
        backend.domains["other"] = "another-library"
        try await host.deactivate(using: index)
        #expect(Set(backend.items.keys) == ["other"])
        #expect(!host.systemSearchEnabled)
        #expect(throws: SystemIntegrationError.privacyDisabled) {
            try runtime.perform(.open(reference))
        }
        #expect(host.pendingAction == nil)
    }

    @Test func cancellationPreventsIntentSideEffects() async throws {
        let runtime = CaptureIntentRuntime()
        let host = CaptureSystemBridge()
        runtime.host = host
        let task = Task { @MainActor in
            try Task.checkCancellation()
            try runtime.perform(.stageText("synthetic cancelled"))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(host.pendingAction == nil)
    }

    @Test func actualIntentAndEntityQueryDispatch() async throws {
        let runtime = CaptureIntentRuntime.shared
        let previous = runtime.host
        defer { runtime.host = previous }
        runtime.host = nil
        let find = FindCapturesIntent()
        find.query = "indigo"
        await #expect(throws: SystemIntegrationError.unavailable) { _ = try await find.perform() }
        let host = CaptureSystemBridge()
        host.install()
        try host.refresh(libraryID: library, captures: [fixture()], systemSearchEnabled: true)
        _ = try await find.perform()
        #expect(host.consumeAction() == .find("indigo"))
        let entities = try await CaptureEntityQuery().entities(matching: "indigo")
        #expect(entities.map(\.id) == [reference.id])
        let open = OpenCaptureIntent()
        open.capture = try #require(entities.first)
        _ = try await open.perform()
        #expect(host.consumeAction() == .open(reference))
        let draft = CaptureTextIntent()
        draft.text = "explicit synthetic draft"
        _ = try await draft.perform()
        #expect(host.consumeAction() == .stageText("explicit synthetic draft"))
        let index = SpotlightCoordinator(libraryID: library, backend: MemoryIndex())
        try await host.deactivate(using: index)
        await #expect(throws: SystemIntegrationError.privacyDisabled) {
            _ = try await open.perform()
        }
        #expect(host.pendingAction == nil)
    }

    @Test func minimalForegroundIntentContracts() {
        #expect(FindCapturesIntent.openAppWhenRun)
        #expect(OpenCaptureIntent.openAppWhenRun)
        #expect(CaptureTextIntent.openAppWhenRun)
        #expect(CapdShortcutCatalog.shortcuts.count == 3)
        if #available(iOS 26, macOS 26, *) {
            #expect(FindCapturesIntent.supportedModes == .foreground(.immediate))
        }
    }
}

@MainActor
private final class HeldIntentPreparation {
    var waiters: [CheckedContinuation<Void, Never>] = []
    private var ready = false

    func wait() async {
        guard !ready else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        ready = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
