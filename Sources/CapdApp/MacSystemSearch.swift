import CapdKit
import CapdSystemIntegration
import Foundation

/// Query actions read a fresh validated snapshot; index maintenance is separate.
@MainActor
final class MacSystemSearch: CaptureActionHost {
    private(set) var systemSearchEnabled: Bool
    private let paths: StoragePaths
    private let localID: UUID
    private let defaults: UserDefaults
    private let backend: any SpotlightBackend
    private let dispatch: (CaptureAction, Int64?) throws -> Void
    private var coordinator: SpotlightCoordinator?
    private var tail: Task<Void, Never>?
    private let cleanupKey: String
    var reportIssue: (String?) -> Void = { _ in }

    init(
        paths: StoragePaths, enabled: Bool, defaults: UserDefaults = .standard,
        backend: (any SpotlightBackend)? = nil,
        dispatch: @escaping (CaptureAction, Int64?) throws -> Void
    ) {
        self.paths = paths
        self.defaults = defaults
        self.dispatch = dispatch
        systemSearchEnabled = enabled
        self.backend = backend ?? CoreSpotlightBackend(name: "dev.jxd.capd.mac.captures")
        let identityKey = "capd.system-search.local-id." + paths.databaseURL.path
        cleanupKey = "capd.system-search.indexed-id." + paths.databaseURL.path
        if let raw = defaults.string(forKey: identityKey), let id = UUID(uuidString: raw) {
            localID = id
        } else {
            localID = UUID()
            defaults.set(localID.uuidString, forKey: identityKey)
        }
    }

    func install() { CaptureIntentRuntime.shared.host = self }

    func setEnabled(_ enabled: Bool) {
        systemSearchEnabled = enabled
        refresh()
    }

    func search(_ query: String) throws -> [SearchCapture] {
        let current = try snapshot()
        return current.captures.filter {
            query.isEmpty
                || ($0.title + " " + $0.manualTags.joined(separator: " "))
                    .localizedStandardContains(query)
        }.map { Self.record($0, libraryID: current.libraryID) }
    }

    func resolve(_ reference: CaptureReference) throws -> SearchCapture? {
        let current = try snapshot()
        guard current.libraryID == reference.libraryID,
            let entry = current.captures.first(where: { $0.id == reference.captureID })
        else { return nil }
        return Self.record(entry, libraryID: current.libraryID)
    }

    func handle(_ action: CaptureAction) throws {
        if case .open(let reference) = action {
            let current = try snapshot()
            guard current.libraryID == reference.libraryID,
                let entry = current.captures.first(where: { $0.id == reference.captureID })
            else { throw SystemIntegrationError.missingCapture }
            try dispatch(action, entry.localID)
        } else {
            try dispatch(action, nil)
        }
    }

    func receive(_ route: CaptureRoute) {
        do {
            switch route {
            case .find(let query): try CaptureIntentRuntime.shared.perform(.find(query))
            case .open(let reference): try CaptureIntentRuntime.shared.perform(.open(reference))
            }
        } catch { reportIssue(error.localizedDescription) }
    }

    func refresh() {
        let previous = tail
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let current = self.systemSearchEnabled ? try self.snapshot() : nil
                if let oldID = self.defaults.string(forKey: self.cleanupKey).flatMap(
                    UUID.init(uuidString:)),
                    current?.libraryID != oldID
                {
                    try await SpotlightCoordinator(libraryID: oldID, backend: self.backend)
                        .reconcile([], enabled: false)
                    self.defaults.removeObject(forKey: self.cleanupKey)
                    self.coordinator = nil
                }
                if let current, self.systemSearchEnabled {
                    if self.coordinator?.libraryID != current.libraryID {
                        self.coordinator = SpotlightCoordinator(
                            libraryID: current.libraryID, backend: self.backend)
                    }
                    self.defaults.set(current.libraryID.uuidString, forKey: self.cleanupKey)
                    try await self.coordinator?.reconcile(
                        current.captures.map {
                            Self.record($0, libraryID: current.libraryID)
                        }, enabled: true)
                }
                self.reportIssue(nil)
            } catch {
                if let oldID = self.defaults.string(forKey: self.cleanupKey).flatMap(
                    UUID.init(uuidString:))
                {
                    do {
                        try await SpotlightCoordinator(libraryID: oldID, backend: self.backend)
                            .reconcile([], enabled: false)
                        self.defaults.removeObject(forKey: self.cleanupKey)
                        self.coordinator = nil
                    } catch {
                        // Retain cleanup scope for retry.
                    }
                }
                self.reportIssue(error.localizedDescription)
            }
        }
    }

    func settle() async { await tail?.value }

    private func snapshot() throws -> MacDiscoverySnapshot {
        guard systemSearchEnabled else { throw SystemIntegrationError.privacyDisabled }
        return try MacDiscoverySnapshot.load(paths: paths, localLibraryID: localID)
    }

    private static func record(_ entry: MacDiscoveryCapture, libraryID: UUID) -> SearchCapture {
        SearchCapture(
            reference: CaptureReference(libraryID: libraryID, captureID: entry.id),
            title: entry.title, keywords: entry.manualTags, revision: entry.revision)
    }
}
