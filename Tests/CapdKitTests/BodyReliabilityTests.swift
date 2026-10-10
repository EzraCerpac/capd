import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdKit

@Suite("Article body reliability")
struct BodyReliabilityTests {
    @Test("Missing, thin, consent and substantive text remain distinct")
    func classification() {
        #expect(BodyClassifier.classify(nil) == .failed)
        #expect(BodyClassifier.classify(ExtractedBody(text: " \n ")) == .failed)
        #expect(BodyClassifier.classify(ExtractedBody(text: "A short useful page")) == .thin)
        #expect(BodyClassifier.classify(ExtractedBody(text: consent)) == .thin)
        #expect(BodyClassifier.classify(ExtractedBody(text: article)) == .ok)
        #expect(BodyClassifier.classify(ExtractedBody(text: consent + article)) == .ok)
        let privacyArticle =
            "The guide explains cookie preferences and necessary cookies. " + article
        #expect(BodyClassifier.classify(ExtractedBody(text: privacyArticle)) == .ok)
        let listArticle =
            article.replacingOccurrences(of: ".", with: "")
            + "We use cookies and similar technologies Necessary cookies Accept all cookies"
        #expect(BodyClassifier.classify(ExtractedBody(text: listArticle)) == .ok)
    }

    @Test("Existing salvage recovers an article when Readability chose consent text")
    func salvageRecoversArticle() {
        let html = "<html><body><div>\(consent)</div><article>\(article)</article></body></html>"
        let result = BodyExtractionPipeline.select(
            readable: ExtractedBody(text: consent), html: html,
            url: URL(string: "https://example.invalid/article")!, source: .tab)
        #expect(result.status == .ok)
        #expect(result.body == article.trimmingCharacters(in: .whitespaces))
        #expect(result.source == .tab)
        let missing = BodyExtractionPipeline.select(
            readable: nil, html: "<body></body>",
            url: URL(string: "https://example.invalid/empty")!, source: .fetch)
        #expect(missing.status == .failed)
        #expect(missing.body == nil)
    }

    @Test("Fallback keeps useful tab text when a fetch is poorer")
    func fallbackQuality() {
        let tab = BodyExtractionResult(classifying: ExtractedBody(text: article), source: .tab)
        let cookies = BodyExtractionResult(
            classifying: ExtractedBody(text: consent), source: .fetch)
        let failed = BodyExtractionResult(classifying: nil, source: .fetch)
        let short = BodyExtractionResult(
            classifying: ExtractedBody(text: "Useful short text"), source: .tab)
        #expect(tab.preferring(cookies) == tab)
        #expect(tab.preferring(failed) == tab)
        #expect(short.preferring(cookies) == short)
        #expect(cookies.preferring(short) == short)
        #expect(cookies.preferring(tab) == tab)
        #expect(tab.preferring(tab) == tab)
    }

    @Test(
        "Weak results exhaust a finite retry budget and stay idempotent",
        arguments: ["", "Short page", consent])
    func retryBounds(text: String) async throws {
        try await fixture { store in
            let id = try link(in: store)
            let result = BodyExtractionResult(
                classifying: ExtractedBody(text: text), source: .fetch)
            let service = EnrichmentService(
                store: store, steps: [SyntheticBodyStep(results: [result])])
            for attempt in 1...EnrichmentService.maxAttempts {
                let capture = try #require(try await service.processNext())
                #expect(capture.attemptCount == attempt)
                #expect(capture.body == result.body)
                #expect(
                    capture.enrichmentState
                        == (attempt < EnrichmentService.maxAttempts
                            ? .pending : result.enrichmentState))
            }
            #expect(try await service.processNext() == nil)
            #expect(try await service.process(captureID: id) == nil)
            #expect(try service.reclaimStale(olderThan: nil) == 0)
            #expect(try service.pendingCount() == 0)
        }
    }

    @Test("A retry stops as soon as article text is saved")
    func retryRecovers() async throws {
        try await fixture { store in
            let id = try link(in: store)
            let weak = BodyExtractionResult(classifying: ExtractedBody(text: consent), source: .tab)
            let good = BodyExtractionResult(
                classifying: ExtractedBody(text: article), source: .fetch)
            let service = EnrichmentService(
                store: store, steps: [SyntheticBodyStep(results: [weak, good])])
            #expect(try await service.processNext()?.enrichmentState == .pending)
            let saved = try #require(try await service.processNext())
            #expect(saved.body == article)
            #expect(saved.bodyStatus == .ok)
            #expect(saved.bodySource == .fetch)
            #expect(saved.attemptCount == 2)
            #expect(try await service.process(captureID: id) == nil)
            #expect(try service.pendingCount() == 0)
        }
    }

    @Test("Poor refreshes preserve better bodies and originals", arguments: [false, true])
    func preservesSavedBody(synced: Bool) async throws {
        try await fixture(synced: synced) { store in
            let id = try link(in: store)
            let claim = try #require(try store.claimForEnrichment(id: id))
            let good = BodyExtractionResult(classifying: ExtractedBody(text: article), source: .tab)
            let original = try store.completeEnrichment(
                id: id, result: StepResult(bodyExtraction: good), state: .ok, expectedClaim: claim)
            let pending = try store.syncClient?.pendingOperations()
            let longLogin =
                "Sign in to continue reading. "
                + String(repeating: "Subscriber access information. ", count: 600)
            #expect(BodyClassifier.classify(ExtractedBody(text: longLogin)) == .ok)
            for text in [
                "", "Useful short text", consent,
                "Shorter article. " + String(article.prefix(1800)),
                longLogin, article + article,
            ] {
                #expect(try store.requeueCaptures(ids: [id]) == 1)
                let worse = BodyExtractionResult(
                    classifying: ExtractedBody(text: text), source: .fetch)
                let service = EnrichmentService(
                    store: store, steps: [SyntheticBodyStep(results: [worse])])
                let saved = try #require(try await service.processNext())
                #expect(saved.body == original.body)
                #expect(saved.bodyStatus == .ok)
                #expect(saved.bodySource == .tab)
                #expect(saved.enrichmentState == .ok)
                #expect(saved.title == original.title)
                #expect(saved.url == original.url)
                #expect(saved.selection == original.selection)
                #expect(saved.note == original.note)
                #expect(try store.syncClient?.pendingOperations() == pending)
                #expect(try await service.processNext() == nil)
            }
        }
    }

    @Test("Legacy consent bodies get bounded repair without deleting the original")
    func legacyConsentRepair() async throws {
        try await fixture { store in
            let id = try link(in: store)
            _ = try store.claimForEnrichment(id: id)
            _ = try store.completeEnrichment(
                id: id,
                result: StepResult(bodyExtraction: .init(body: consent, status: .ok, source: .tab)),
                state: .ok)
            let weak = BodyExtractionResult(classifying: nil, source: .fetch)
            let service = EnrichmentService(
                store: store, steps: [SyntheticBodyStep(results: [weak])])
            #expect(try service.recoverBoilerplateBodies() == 1)
            #expect(try service.recoverBoilerplateBodies() == 0)
            for _ in 2...EnrichmentService.maxAttempts {
                let saved = try #require(try await service.processNext())
                #expect(saved.body == consent)
                #expect(saved.bodyStatus == .thin)
                #expect(saved.bodySource == .tab)
            }
            #expect(try service.recoverBoilerplateBodies() == 0)
            #expect(try service.pendingCount() == 0)
        }
    }

    @Test("Longer login stubs preserve useful thin text while filling a title hole")
    func retainsUsefulThinText() async throws {
        try await fixture { store in
            let id = try #require(
                try CaptureService(store: store).ingest(
                    CaptureRequest(url: "https://example.invalid/brief")
                ).capture.id)
            _ = try store.claimForEnrichment(id: id)
            let brief = String(repeating: "Brief observations of alpine bird migration. ", count: 8)
            _ = try store.completeEnrichment(
                id: id,
                result: StepResult(
                    bodyExtraction: .init(classifying: ExtractedBody(text: brief), source: .tab)),
                state: .thin)
            #expect(try store.requeueCaptures(ids: [id]) == 1)
            let login =
                "Sign in to continue reading. "
                + String(repeating: "Subscriber access information. ", count: 80)
            let result = BodyExtractionResult(
                classifying: ExtractedBody(text: login, title: "Brief observations"), source: .fetch
            )
            #expect(result.status == .thin)
            let service = EnrichmentService(
                store: store, steps: [SyntheticBodyStep(results: [result])])
            let saved = try #require(try await service.processNext())
            #expect(saved.body == brief)
            #expect(saved.bodyStatus == .thin)
            #expect(saved.bodySource == .tab)
            #expect(saved.title == "Brief observations")
            #expect(saved.enrichmentState == .pending)
        }
    }

    @Test("Synced legacy consent is repairable but repeated projection cannot reset retries")
    func syncedConsentRetryBounds() async throws {
        try await fixture(synced: true) { store in
            let id = try link(in: store)
            let client = try #require(store.syncClient)
            var projected = try #require(try client.captures().first)
            projected.generated = GeneratedContent(body: consent, bodyIsThin: false)
            let record = projected
            let service = EnrichmentService(
                store: store,
                steps: [SyntheticBodyStep(results: [.init(classifying: nil, source: .fetch)])])
            for attempt in 1...EnrichmentService.maxAttempts {
                try await store.dbPool.write { db in
                    try StoreSync.project(db, record: record, paths: store.paths)
                }
                let capture = try #require(try await service.process(captureID: id))
                #expect(capture.attemptCount == attempt)
                #expect(capture.body == consent)
            }
            try await store.dbPool.write { db in
                try StoreSync.project(db, record: record, paths: store.paths)
            }
            #expect(try await service.processNext() == nil)
            #expect(try service.reclaimStale() == 0)
        }
    }
}

private let consent = String(
    repeating:
        "We use cookies and similar technologies to store device information. Accept all cookies or manage consent preferences. Necessary cookies support this website. Performance cookies measure visits. ",
    count: 22)
private let article = String(
    repeating:
        "Field researchers followed alpine birds across several valleys during spring migration. Their observations recorded flight patterns, nesting sites and changing weather. The study compares the routes across years and explains how habitat influences each journey. ",
    count: 30)

private struct SyntheticBodyStep: ProcessingStep {
    let results: [BodyExtractionResult]
    func applies(to capture: Capture) -> Bool { capture.kind == .link }
    func run(_ capture: Capture, context: ProcessingContext) async throws -> StepResult {
        StepResult(bodyExtraction: results[min(capture.attemptCount - 1, results.count - 1)])
    }
}

private func link(in store: Store) throws -> Int64 {
    try #require(
        try CaptureService(store: store).ingest(
            CaptureRequest(
                url: "https://example.invalid/article", text: "Original selection",
                title: "Original title", note: "Original note")
        ).capture.id)
}

private func fixture(synced: Bool = false, _ body: (Store) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
        "capd-body-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let binding = synced ? SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()) : nil
    try await body(Store(paths: StoragePaths(root: root), syncBinding: binding))
}
