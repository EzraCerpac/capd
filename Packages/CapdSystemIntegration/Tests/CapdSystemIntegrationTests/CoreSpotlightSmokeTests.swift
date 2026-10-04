import CoreSpotlight
import Foundation
import Testing
import os

@testable import CapdSystemIntegration

struct CoreSpotlightSmokeTests {
    @Test @MainActor func namedIndexUsesCompleteProtection() {
        let backend = CoreSpotlightBackend(name: "dev.jxd.capd.synthetic.\(UUID().uuidString)")
        if #available(iOS 27, macOS 27, *) {
            #expect(backend.protectionClass == .complete)
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["CAPD_SPOTLIGHT_SYNTHETIC_SMOKE"] == "1"))
    @MainActor func syntheticSystemIndexRoundTrip() async throws {
        let libraryID = UUID()
        let namespace = "dev.jxd.capd.synthetic.\(UUID().uuidString.lowercased())"
        let backend = CoreSpotlightBackend(name: namespace)
        let coordinator = SpotlightCoordinator(
            libraryID: libraryID, namespace: namespace, backend: backend)
        let capture = SearchCapture(
            reference: CaptureReference(libraryID: libraryID, captureID: UUID()),
            title: "Synthetic cobalt otter", text: "synthetic cobalt otter spotlight fixture")
        do {
            try await coordinator.reconcile([capture], enabled: true)
            var found = false
            for _ in 0..<20 {
                try Task.checkCancellation()
                if try await query(domain: coordinator.domain).contains(capture.id) {
                    found = true
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            #expect(found, "Core Spotlight should return this task's synthetic item")
            try await coordinator.reconcile([], enabled: false)
            var removed = false
            for _ in 0..<20 {
                if try await query(domain: coordinator.domain).isEmpty {
                    removed = true
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            #expect(removed, "Scoped cleanup should remove this task's item")
        } catch {
            try await backend.delete(domain: coordinator.domain)
            throw error
        }
    }

    @MainActor private func query(domain: String) async throws -> [String] {
        let results = OSAllocatedUnfairLock(initialState: [String]())
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title"]
        let query = CSSearchQuery(
            queryString: "domainIdentifier == '\(domain)' && textContent == '*cobalt*'cd",
            queryContext: context)
        query.foundItemsHandler = { items in
            let identifiers = items.map(\.uniqueIdentifier)
            results.withLock { $0.append(contentsOf: identifiers) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            query.completionHandler = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: results.withLock { $0 })
                }
            }
            query.start()
        }
    }
}
