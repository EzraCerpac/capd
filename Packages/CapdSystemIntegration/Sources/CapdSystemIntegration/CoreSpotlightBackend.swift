import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

@MainActor
public final class CoreSpotlightBackend: SpotlightBackend {
    private let index: CSSearchableIndex

    public init(name: String) {
        index = CSSearchableIndex(name: name, protectionClass: .complete)
    }

    #if compiler(>=6.4)
        @available(iOS 27, macOS 27, *)
        var protectionClass: FileProtectionType { index.protectionClass }
    #endif

    public static func item(_ capture: SearchCapture, domain: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = String(capture.title.prefix(256))
        attributes.contentDescription = String(capture.text.prefix(256))
        attributes.textContent = String(capture.text.prefix(8192))
        attributes.keywords = capture.keywords.prefix(32).map { String($0.prefix(80)) }
        attributes.contentURL = CaptureRoute.open(capture.reference).url
        let item = CSSearchableItem(
            uniqueIdentifier: capture.id, domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = Date().addingTimeInterval(30 * 24 * 60 * 60)
        return item
    }

    public func replace(_ captures: [SearchCapture], domain: String) async throws {
        guard captures.allSatisfy({ $0.isBounded && !$0.deleted }) else {
            throw SystemIntegrationError.invalidSnapshot
        }
        guard CSSearchableIndex.isIndexingAvailable() else {
            throw SystemIntegrationError.unavailable
        }
        let items = captures.map { Self.item($0, domain: domain) }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            index.indexSearchableItems(items) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    public func delete(identifiers: [String]) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteSearchableItems(withIdentifiers: identifiers) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    public func delete(domain: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

extension CaptureRoute {
    public init?(spotlightActivity: NSUserActivity) {
        guard spotlightActivity.activityType == CSSearchableItemActionType,
            let identifier = spotlightActivity.userInfo?[CSSearchableItemActivityIdentifier]
                as? String,
            let reference = CaptureReference(identifier: identifier)
        else { return nil }
        self = .open(reference)
    }
}
