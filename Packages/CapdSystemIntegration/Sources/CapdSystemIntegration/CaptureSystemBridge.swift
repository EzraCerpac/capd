import Foundation
import Observation

@MainActor
@Observable
public final class CaptureSystemBridge: CaptureActionHost {
    public private(set) var systemSearchEnabled = false
    public private(set) var pendingAction: CaptureAction?
    public private(set) var routingError: String?
    private var libraryID: UUID?
    private var captures: [String: SearchCapture] = [:]
    private var deferredRoute: CaptureRoute?
    private let preparation: @MainActor () async throws -> Void

    public init(preparingForIntent: @escaping @MainActor () async throws -> Void = {}) {
        preparation = preparingForIntent
    }

    public func prepareForIntent() async throws { try await preparation() }

    /// Installs the host early in app startup, before a foreground intent performs.
    public func install() { CaptureIntentRuntime.shared.host = self }

    /// Refresh with a complete canonical snapshot after local changes and sync projection.
    public func refresh(libraryID: UUID, captures: [SearchCapture], systemSearchEnabled: Bool)
        throws
    {
        guard self.libraryID == nil || self.libraryID == libraryID else {
            throw SystemIntegrationError.invalidSnapshot
        }
        guard captures.allSatisfy({ $0.reference.libraryID == libraryID && $0.isBounded }),
            Set(captures.map(\.id)).count == captures.count
        else { throw SystemIntegrationError.invalidSnapshot }
        self.libraryID = libraryID
        self.captures = Dictionary(
            uniqueKeysWithValues: captures.filter { !$0.deleted }.map { ($0.id, $0) })
        self.systemSearchEnabled = systemSearchEnabled
        if let route = deferredRoute {
            deferredRoute = nil
            receive(route)
        }
    }

    public func search(_ query: String) throws -> [SearchCapture] {
        guard libraryID != nil else { throw SystemIntegrationError.unavailable }
        return captures.values.filter {
            query.isEmpty
                || ($0.title + "\n" + $0.text + "\n" + $0.keywords.joined(separator: " "))
                    .localizedStandardContains(query)
        }.sorted { $0.id < $1.id }
    }

    public func resolve(_ reference: CaptureReference) throws -> SearchCapture? {
        guard libraryID != nil else { throw SystemIntegrationError.unavailable }
        guard reference.libraryID == libraryID else { return nil }
        return captures[reference.id]
    }

    public func handle(_ action: CaptureAction) throws {
        guard pendingAction == nil else { throw SystemIntegrationError.actionPending }
        pendingAction = action
        routingError = nil
    }

    public func receive(_ route: CaptureRoute) {
        guard libraryID != nil else {
            deferredRoute = route
            return
        }
        do {
            switch route {
            case .open(let reference): try CaptureIntentRuntime.shared.perform(.open(reference))
            case .find(let query): try CaptureIntentRuntime.shared.perform(.find(query))
            }
        } catch {
            routingError = error.localizedDescription
        }
    }

    public func consumeAction() -> CaptureAction? {
        defer { pendingAction = nil }
        return pendingAction
    }

    public func consumeRoutingError() -> String? {
        defer { routingError = nil }
        return routingError
    }

    /// Clears the host immediately, then removes only the active library's Spotlight domain.
    public func deactivate(using coordinator: SpotlightCoordinator) async throws {
        guard libraryID == nil || coordinator.libraryID == libraryID else {
            throw SystemIntegrationError.invalidSnapshot
        }
        invalidate()
        try await coordinator.reconcile([], enabled: false)
    }

    /// Withdraws library-dependent state while keeping draft text available for review.
    /// Index deletion remains the caller's responsibility through its coordinator.
    public func invalidate(preservingDeferredRoute: Bool = false) {
        systemSearchEnabled = false
        libraryID = nil
        captures = [:]
        switch pendingAction {
        case .stageText: break
        default: pendingAction = nil
        }
        routingError = nil
        if !preservingDeferredRoute { deferredRoute = nil }
    }
}
