import AppIntents
import Foundation
import Testing

@testable import CapdSystemIntegration

extension IntentHostTests {
    @Test func secondDraftIntentDoesNotReplaceAnAcceptedDraft() async throws {
        let runtime = CaptureIntentRuntime.shared
        let previous = runtime.host
        defer { runtime.host = previous }
        let host = CaptureSystemBridge()
        host.install()
        let first = CaptureTextIntent()
        first.text = "first synthetic draft awaiting review"
        let second = CaptureTextIntent()
        second.text = "second synthetic draft awaiting review"

        _ = try await first.perform()
        await #expect(throws: SystemIntegrationError.actionPending) {
            _ = try await second.perform()
        }
        #expect(host.pendingAction == .stageText(first.text))
        #expect(host.consumeAction() == .stageText(first.text))
        #expect(host.consumeAction() == nil)

        _ = try await second.perform()
        #expect(host.consumeAction() == .stageText(second.text))
        #expect(host.consumeAction() == nil)
    }

    @Test func routesDoNotReplaceAnAcceptedDraft() throws {
        let runtime = CaptureIntentRuntime.shared
        let previous = runtime.host
        defer { runtime.host = previous }
        let host = CaptureSystemBridge()
        host.install()
        let reference = CaptureReference(libraryID: UUID(), captureID: UUID())
        let capture = SearchCapture(reference: reference, title: "Synthetic saved capture")
        try host.refresh(
            libraryID: reference.libraryID, captures: [capture], systemSearchEnabled: true)
        let draft = CaptureAction.stageText("synthetic draft awaiting review")
        try runtime.perform(draft)

        for route in [CaptureRoute.find("synthetic"), .open(reference)] {
            host.receive(route)
            #expect(
                host.consumeRoutingError()
                    == SystemIntegrationError.actionPending.localizedDescription)
            #expect(host.pendingAction == draft)
        }
        #expect(host.consumeAction() == draft)
        host.receive(.open(reference))
        #expect(host.consumeRoutingError() == nil)
        #expect(host.consumeAction() == .open(reference))
    }

    @Test func occupiedActionRetainsPrivacyAndReferenceValidation() throws {
        let runtime = CaptureIntentRuntime()
        let host = CaptureSystemBridge()
        runtime.host = host
        let reference = CaptureReference(libraryID: UUID(), captureID: UUID())
        let capture = SearchCapture(reference: reference, title: "Synthetic saved capture")
        let draft = CaptureAction.stageText("synthetic draft awaiting review")
        try runtime.perform(draft)
        #expect(throws: SystemIntegrationError.privacyDisabled) {
            try runtime.perform(.find("synthetic"))
        }
        try host.refresh(
            libraryID: reference.libraryID, captures: [capture], systemSearchEnabled: true)
        let otherLibrary = CaptureReference(libraryID: UUID(), captureID: reference.captureID)
        #expect(throws: SystemIntegrationError.missingCapture) {
            try runtime.perform(.open(otherLibrary))
        }
        #expect(host.pendingAction == draft)
        host.invalidate()
        #expect(host.consumeAction() == draft)

        for action in [CaptureAction.find("synthetic"), .open(reference)] {
            try host.refresh(
                libraryID: reference.libraryID, captures: [capture], systemSearchEnabled: true)
            try runtime.perform(action)
            #expect(throws: SystemIntegrationError.actionPending) {
                try runtime.perform(draft)
            }
            #expect(host.pendingAction == action)
            host.invalidate()
            #expect(host.consumeAction() == nil)
        }
    }

    @Test func repeatedFailingRoutesProduceConsumableErrors() throws {
        let runtime = CaptureIntentRuntime.shared
        let previous = runtime.host
        defer { runtime.host = previous }
        let host = CaptureSystemBridge()
        host.install()
        let libraryID = UUID()
        try host.refresh(libraryID: libraryID, captures: [], systemSearchEnabled: true)
        let staleRoute = CaptureRoute.open(
            CaptureReference(libraryID: libraryID, captureID: UUID()))
        for _ in 0..<2 {
            host.receive(staleRoute)
            #expect(host.routingError == SystemIntegrationError.missingCapture.localizedDescription)
            #expect(
                host.consumeRoutingError()
                    == SystemIntegrationError.missingCapture.localizedDescription)
            #expect(host.routingError == nil)
            #expect(host.consumeRoutingError() == nil)
            #expect(host.pendingAction == nil)
        }
    }

    @Test func draftSurvivesSearchInvalidationBeforeConsumption() async throws {
        let runtime = CaptureIntentRuntime.shared
        let previous = runtime.host
        defer { runtime.host = previous }
        for preservingDeferredRoute in [false, true] {
            let host = CaptureSystemBridge()
            host.install()
            let draft = CaptureTextIntent()
            draft.text = "synthetic draft awaiting search reconciliation"
            _ = try await draft.perform()

            host.invalidate(preservingDeferredRoute: preservingDeferredRoute)
            host.invalidate()
            try host.refresh(libraryID: UUID(), captures: [], systemSearchEnabled: false)

            #expect(host.consumeAction() == .stageText(draft.text))
            #expect(host.consumeAction() == nil)
        }
    }

    @Test func invalidationStillWithdrawsLibraryDependentActions() throws {
        let runtime = CaptureIntentRuntime()
        let host = CaptureSystemBridge()
        runtime.host = host
        let reference = CaptureReference(libraryID: UUID(), captureID: UUID())
        let capture = SearchCapture(reference: reference, title: "Synthetic saved capture")
        for action in [CaptureAction.open(reference), .find("synthetic")] {
            try host.refresh(
                libraryID: reference.libraryID, captures: [capture], systemSearchEnabled: true)
            try runtime.perform(action)
            host.invalidate(preservingDeferredRoute: true)
            try host.refresh(libraryID: UUID(), captures: [], systemSearchEnabled: true)
            #expect(host.consumeAction() == nil)
            host.invalidate()
        }
    }

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
