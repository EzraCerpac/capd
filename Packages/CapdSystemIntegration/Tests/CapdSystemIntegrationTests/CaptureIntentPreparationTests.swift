import AppIntents
import Foundation
import Testing

@testable import CapdSystemIntegration

extension IntentHostTests {
    @Test func draftTextSkipsFailedSearchPreparationWithoutSaving() async throws {
        let runtime = CaptureIntentRuntime.shared
        let previous = runtime.host
        defer { runtime.host = previous }
        for hasSnapshot in [false, true] {
            var preparationCalls = 0
            let host = CaptureSystemBridge(preparingForIntent: {
                preparationCalls += 1
                throw SystemIntegrationError.unavailable
            })
            host.install()
            if hasSnapshot {
                try host.refresh(libraryID: UUID(), captures: [], systemSearchEnabled: false)
            }
            let draft = CaptureTextIntent()
            draft.text = "synthetic draft awaiting review"

            _ = try await draft.perform()

            #expect(preparationCalls == 0)
            #expect(!host.systemSearchEnabled)
            #expect(host.consumeAction() == .stageText("synthetic draft awaiting review"))
            #expect(host.consumeAction() == nil)
            if hasSnapshot {
                #expect(try host.search("").isEmpty)
            } else {
                #expect(throws: SystemIntegrationError.unavailable) { try host.search("") }
            }
        }
    }

    @Test func findAndOpenStillRequireSearchPreparation() async throws {
        let runtime = CaptureIntentRuntime.shared
        let previous = runtime.host
        defer { runtime.host = previous }
        var preparationCalls = 0
        let host = CaptureSystemBridge(preparingForIntent: {
            preparationCalls += 1
            throw SystemIntegrationError.unavailable
        })
        host.install()
        let reference = CaptureReference(libraryID: UUID(), captureID: UUID())
        let capture = SearchCapture(reference: reference, title: "Synthetic saved capture")
        try host.refresh(
            libraryID: reference.libraryID, captures: [capture], systemSearchEnabled: true)
        let find = FindCapturesIntent()
        find.query = "synthetic"
        await #expect(throws: SystemIntegrationError.unavailable) { _ = try await find.perform() }
        #expect(preparationCalls == 1)
        #expect(host.pendingAction == nil)
        let open = OpenCaptureIntent()
        open.capture = CaptureEntity(capture)
        await #expect(throws: SystemIntegrationError.unavailable) { _ = try await open.perform() }
        #expect(preparationCalls == 2)
        #expect(host.pendingAction == nil)
        #expect(try host.search("") == [capture])
    }
}
