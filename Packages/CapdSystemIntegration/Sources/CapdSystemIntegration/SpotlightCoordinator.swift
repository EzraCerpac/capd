import Foundation

@MainActor
public protocol SpotlightBackend: AnyObject {
    func replace(_ captures: [SearchCapture], domain: String) async throws
    func delete(identifiers: [String]) async throws
    func delete(domain: String) async throws
}

@MainActor
public final class SpotlightCoordinator {
    private struct IndexedCapture {
        let capture: SearchCapture
        let donatedAt: Date
    }

    public let libraryID: UUID
    public let domain: String
    private let backend: any SpotlightBackend
    private var indexed: [String: IndexedCapture] = [:]
    private let now: @MainActor () -> Date
    private var initialized = false
    private var consent = false
    private var tail: Task<Void, Never>?

    public init(
        libraryID: UUID, namespace: String = "dev.jxd.capd.captures", backend: any SpotlightBackend,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.libraryID = libraryID
        self.domain = "\(namespace).\(libraryID.uuidString.lowercased())"
        self.backend = backend
        self.now = now
    }

    /// Host revision gates must still reconcile when unchanged items need renewal.
    public var needsRenewal: Bool {
        let date = now()
        return consent && (!initialized || indexed.values.contains { due($0, at: date) })
    }

    private func due(_ item: IndexedCapture, at date: Date) -> Bool {
        date < item.donatedAt || date.timeIntervalSince(item.donatedAt) >= 24 * 60 * 60
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
        let donatedAt = now()
        let changed = visible.values.filter {
            guard let previous = indexed[$0.id] else { return true }
            return previous.capture != $0 || due(previous, at: donatedAt)
        }.sorted { $0.id < $1.id }
        if !changed.isEmpty {
            do {
                try await backend.replace(changed, domain: domain)
            } catch {
                initialized = false
                throw error
            }
            for capture in changed {
                indexed[capture.id] = IndexedCapture(capture: capture, donatedAt: donatedAt)
            }
        }
    }
}
