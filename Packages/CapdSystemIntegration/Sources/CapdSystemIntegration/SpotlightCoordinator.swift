import Foundation

@MainActor
public protocol SpotlightBackend: AnyObject {
    func replace(_ captures: [SearchCapture], domain: String) async throws
    func delete(identifiers: [String]) async throws
    func delete(domain: String) async throws
}

@MainActor
public final class SpotlightCoordinator {
    public let libraryID: UUID
    public let domain: String
    private let backend: any SpotlightBackend
    private var indexed: [String: SearchCapture] = [:]
    private var initialized = false
    private var consent = false
    private var tail: Task<Void, Never>?

    public init(
        libraryID: UUID, namespace: String = "dev.jxd.capd.captures", backend: any SpotlightBackend
    ) {
        self.libraryID = libraryID
        self.domain = "\(namespace).\(libraryID.uuidString.lowercased())"
        self.backend = backend
    }

    /// Reconciles a complete canonical library snapshot. Never pass a filtered search page.
    public func reconcile(_ snapshot: [SearchCapture], enabled: Bool) async throws {
        if enabled { try Task.checkCancellation() }
        consent = enabled
        let predecessor = tail
        let operation = Task { @MainActor in
            await predecessor?.value
            if enabled { try Task.checkCancellation() }
            try await self.apply(snapshot, enabled: enabled)
        }
        tail = Task { _ = try? await operation.value }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            if enabled { operation.cancel() }
        }
    }

    private func apply(_ snapshot: [SearchCapture], enabled: Bool) async throws {
        guard enabled && consent else {
            try await backend.delete(domain: domain)
            indexed = [:]
            initialized = false
            return
        }
        guard snapshot.count <= 1000 else { throw SystemIntegrationError.snapshotTooLarge }
        guard snapshot.allSatisfy({ $0.reference.libraryID == libraryID && $0.isBounded })
        else { throw SystemIntegrationError.invalidSnapshot }
        var latest: [String: SearchCapture] = [:]
        for capture in snapshot {
            if let previous = latest[capture.id] {
                if previous.revision > capture.revision { continue }
                if previous.revision == capture.revision {
                    if previous.deleted { continue }
                    if !capture.deleted && previous != capture {
                        throw SystemIntegrationError.invalidSnapshot
                    }
                }
            }
            latest[capture.id] = capture
        }
        let visible = latest.filter { !$0.value.deleted }
        if !initialized {
            // A fresh process cannot trust in-memory IDs to remove old tombstones or aliases.
            try await backend.delete(domain: domain)
            indexed = [:]
            initialized = true
        }
        try Task.checkCancellation()
        let removed = Set(indexed.keys).subtracting(visible.keys).sorted()
        if !removed.isEmpty {
            try await backend.delete(identifiers: removed)
            for id in removed { indexed.removeValue(forKey: id) }
        }
        try Task.checkCancellation()
        guard consent else { return }
        let changed = visible.values.filter { indexed[$0.id] != $0 }.sorted { $0.id < $1.id }
        if !changed.isEmpty {
            try await backend.replace(changed, domain: domain)
            for capture in changed { indexed[capture.id] = capture }
        }
    }
}
