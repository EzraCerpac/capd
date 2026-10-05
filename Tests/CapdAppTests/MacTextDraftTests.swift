import CapdSystemIntegration
import Foundation
import Testing

@testable import CapdApp
@testable import CapdKit

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MacTextDraftTests {
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
            }, save: { saves.append($0) })
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
    let text: String
    let complete: @MainActor (String?) -> Void
    var shown = false
    init(text: String, complete: @escaping @MainActor (String?) -> Void) {
        self.text = text
        self.complete = complete
    }
    func show() { shown = true }
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
