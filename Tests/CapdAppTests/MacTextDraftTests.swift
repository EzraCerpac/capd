import CapdSystemIntegration
import Foundation
import Testing

@testable import CapdApp
@testable import CapdAppUI
@testable import CapdKit

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MacTextDraftTests {
    @Test(arguments: ["validation", "persistence", "cancelled"])
    func failedSaveRetainsEditedDraftAndCanRetry(failure: String) async throws {
        weak var draft: SyntheticTextDraft?
        var reject = true
        var attempts: [String] = []
        var failedHUDs = 0
        let coordinator = CaptureCoordinator(
            environment: CaptureEnvironment(
                isSecureInputActive: { false }, frontmostTarget: { nil },
                selectedText: { _ in nil }, browserTab: { _, _ in nil },
                pasteboardFallback: { .nothing }, fetchBody: { false },
                ingest: { request in
                    attempts.append(request.text ?? "")
                    if reject {
                        switch failure {
                        case "validation": throw CaptureError.emptyRequest
                        case "cancelled": throw CancellationError()
                        default: throw DraftSaveFailure.persistence
                        }
                    }
                    return .captured(
                        Capture(kind: .text, selection: request.text, createdAt: request.capturedAt)
                    )
                }, enrich: { _ in }, now: Date.init),
            present: { if $0.style == .failed { failedHUDs += 1 } })
        let drafts = MacTextDrafts(
            make: { text, complete in
                let presentation = SyntheticTextDraft(text: text, complete: complete)
                draft = presentation
                return presentation
            },
            save: { text, complete in
                coordinator.capture(
                    request: CaptureRequest(text: text, fetchBody: false), completion: complete)
            })
        drafts.stage("Original synthetic draft")
        draft?.text = "Edited synthetic draft"
        let complete = try #require(draft?.complete)
        complete("Edited synthetic draft")
        #expect(draft?.saving == true)
        await coordinator.drain()
        #expect(draft != nil)
        #expect(draft?.text == "Edited synthetic draft")
        #expect(draft?.saving == false)
        #expect(attempts == ["Edited synthetic draft"])
        #expect(failedHUDs == 1)
        reject = false
        complete("Corrected synthetic draft")
        await coordinator.drain()
        #expect(attempts == ["Edited synthetic draft", "Corrected synthetic draft"])
        #expect(draft == nil)
    }

    @Test func pendingSaveIgnoresDuplicatesAndOldAttemptCompletions() throws {
        weak var draft: SyntheticTextDraft?
        var submitted: [String] = []
        var completions: [@MainActor (Bool) -> Void] = []
        let drafts = MacTextDrafts(
            make: { text, complete in
                let presentation = SyntheticTextDraft(text: text, complete: complete)
                draft = presentation
                return presentation
            },
            save: { text, complete in
                submitted.append(text)
                completions.append(complete)
            })
        drafts.stage("Synthetic draft")
        let submit = try #require(draft?.complete)
        submit("First edit")
        submit("Duplicate Save")
        #expect(submitted == ["First edit"])
        #expect(draft?.saving == true)
        #expect(draft?.savedCount == 0)
        completions[0](false)
        #expect(draft?.saving == false)
        submit("Corrected edit")
        completions[0](true)
        #expect(draft?.saving == true)
        #expect(draft?.savedCount == 0)
        #expect(submitted == ["First edit", "Corrected edit"])
        completions[1](true)
        #expect(draft == nil)
        completions[1](true)
        submit("Repeated Save")
        #expect(submitted == ["First edit", "Corrected edit"])
    }

    @Test func unavailableSaveKeepsDraftCancelable() throws {
        weak var draft: SyntheticTextDraft?
        var submissions = 0
        let drafts = MacTextDrafts(
            make: { text, complete in
                let presentation = SyntheticTextDraft(text: text, complete: complete)
                draft = presentation
                return presentation
            },
            save: { _, complete in
                submissions += 1
                complete(false)
            })
        drafts.stage("Synthetic unavailable draft")
        let submit = try #require(draft?.complete)
        submit("Edited unavailable draft")
        #expect(draft != nil)
        #expect(draft?.saving == false)
        #expect(draft?.savedCount == 0)
        submit(nil)
        #expect(draft == nil)
        submit("After cancellation")
        #expect(submissions == 1)
    }

    @Test func intentReturnsWithRetainedDraftsAndOnlyExplicitSaveCaptures() async throws {
        var saves: [String] = []
        weak var first: SyntheticTextDraft?
        weak var second: SyntheticTextDraft?
        var created = 0
        let drafts = MacTextDrafts(
            make: { text, complete in
                let draft = SyntheticTextDraft(text: text, complete: complete)
                created += 1
                if created == 1 { first = draft } else { second = draft }
                return draft
            },
            save: { text, complete in
                saves.append(text)
                complete(true)
            })
        let host = MacSystemSearch(
            paths: StoragePaths(
                root: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)),
            enabled: true, backend: DraftUnusedIndex(),
            loadSnapshot: { _, _ in
                Issue.record("Staging text must not read captures")
                throw SystemIntegrationError.missingCapture
            },
            dispatch: { action, _ in
                guard case .stageText(let text) = action else {
                    Issue.record("Unexpected draft action")
                    return
                }
                drafts.stage(text)
            })
        let runtime = CaptureIntentRuntime.shared
        let previous = runtime.host
        defer { runtime.host = previous }
        runtime.host = host
        let intent = CaptureTextIntent()
        intent.text = "Synthetic text awaiting review"
        _ = try await intent.perform()
        #expect(first?.shown == true)
        #expect(first?.text == intent.text)
        #expect(saves.isEmpty)
        intent.text = "Another unsaved draft"
        _ = try await intent.perform()
        #expect(first != nil)
        #expect(second?.shown == true)
        #expect(saves.isEmpty)
        let save = try #require(first?.complete)
        save("Edited text explicitly saved")
        #expect(first == nil)
        #expect(saves == ["Edited text explicitly saved"])
        save("Repeated completion")
        #expect(saves == ["Edited text explicitly saved"])
        second?.complete(nil)
        #expect(second == nil)
        #expect(saves == ["Edited text explicitly saved"])
    }
}

@MainActor
private final class SyntheticTextDraft: MacTextDraftPresentation {
    var text: String
    let complete: @MainActor (String?) -> Void
    var shown = false
    var saving = false
    var savedCount = 0
    init(text: String, complete: @escaping @MainActor (String?) -> Void) {
        self.text = text
        self.complete = complete
    }
    func show() { shown = true }
    func setSaving(_ saving: Bool) { self.saving = saving }
    func saved() { savedCount += 1 }
}

private enum DraftSaveFailure: Error {
    case persistence
}

@MainActor
private final class DraftUnusedIndex: SpotlightBackend {
    func replace(_ captures: [SearchCapture], domain: String) async throws {
        Issue.record("Draft must not modify Spotlight")
    }
    func delete(identifiers: [String]) async throws {
        Issue.record("Draft must not modify Spotlight")
    }
    func delete(domain: String) async throws {
        Issue.record("Draft must not modify Spotlight")
    }
}
