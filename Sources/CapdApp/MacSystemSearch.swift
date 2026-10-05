import CapdKit
import CapdSystemIntegration
import Foundation

/// Query actions read a fresh validated snapshot; index maintenance is separate.
@MainActor
final class MacSystemSearch: CaptureActionHost {
    private(set) var systemSearchEnabled: Bool
    private let paths: StoragePaths
    private let changes: MacDiscoveryChangeMonitor
    private let loadSnapshot: (StoragePaths, UUID) throws -> MacDiscoverySnapshot
    private var indexedRevision: MacDiscoveryChangeMonitor.Revision?
    private let defaults: UserDefaults
    private let backend: any SpotlightBackend
    private let dispatch: (CaptureAction, Int64?) throws -> Void
    private var coordinator: SpotlightCoordinator?
    private var tail: Task<Void, Never>?
    private let cleanupKey: String
    var reportIssue: (String?) -> Void = { _ in }
    var reportRoutingError: (any Error) -> Void = { _ in }

    init(
        paths: StoragePaths, enabled: Bool, defaults: UserDefaults = .standard,
        backend: (any SpotlightBackend)? = nil,
        loadSnapshot: @escaping (StoragePaths, UUID) throws -> MacDiscoverySnapshot = {
            try MacDiscoverySnapshot.load(paths: $0, localLibraryID: $1)
        },
        dispatch: @escaping (CaptureAction, Int64?) throws -> Void
    ) {
        self.paths = paths
        changes = MacDiscoveryChangeMonitor(paths: paths)
        self.loadSnapshot = loadSnapshot
        self.defaults = defaults
        self.dispatch = dispatch
        systemSearchEnabled = enabled
        self.backend = backend ?? CoreSpotlightBackend(name: "dev.jxd.capd.mac.captures")
        cleanupKey = "capd.system-search.indexed-id." + paths.databaseURL.path
    }

    func install() { CaptureIntentRuntime.shared.host = self }

    static func removePersistedIndex(
        paths: StoragePaths, defaults: UserDefaults = .standard,
        backend: (any SpotlightBackend)? = nil
    ) async throws {
        let key = "capd.system-search.indexed-id." + paths.databaseURL.path
        guard let libraryID = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) else {
            return
        }
        let backend = backend ?? CoreSpotlightBackend(name: "dev.jxd.capd.mac.captures")
        try await SpotlightCoordinator(libraryID: libraryID, backend: backend)
            .reconcile([], enabled: false)
        defaults.removeObject(forKey: key)
    }

    func setEnabled(_ enabled: Bool) {
        systemSearchEnabled = enabled
        indexedRevision = nil
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
        try resolve([reference]).first
    }

    func resolve(_ references: [CaptureReference]) throws -> [SearchCapture] {
        let current = try snapshot()
        let captures = Dictionary(uniqueKeysWithValues: current.captures.map { ($0.id, $0) })
        return references.compactMap { reference in
            guard current.libraryID == reference.libraryID,
                let entry = captures[reference.captureID]
            else { return nil }
            return Self.record(entry, libraryID: current.libraryID)
        }
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
        } catch { reportRoutingError(error) }
    }

    func refresh() {
        let previous = tail
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let revision = self.systemSearchEnabled ? try self.changes.revision() : nil
                if let revision, revision == self.indexedRevision { return }
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
                self.indexedRevision = revision
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
        let identity = try databaseIdentity()
        let identityKey = "capd.system-search.local-id." + paths.databaseURL.path
        let fileKey = "capd.system-search.local-file." + paths.databaseURL.path
        let localID: UUID
        if defaults.string(forKey: fileKey) == identity,
            let stored = defaults.string(forKey: identityKey).flatMap(UUID.init(uuidString:))
        {
            localID = stored
        } else {
            localID = UUID()
            defaults.set(localID.uuidString, forKey: identityKey)
            defaults.set(identity, forKey: fileKey)
        }
        let current = try loadSnapshot(paths, localID)
        guard try databaseIdentity() == identity else { throw MacDiscoveryError.invalidIdentity }
        return current
    }

    private func databaseIdentity() throws -> String {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: paths.databaseURL.resolvingSymlinksInPath().path)
        guard let device = attributes[.systemNumber] as? NSNumber,
            let file = attributes[.systemFileNumber] as? NSNumber,
            let created = attributes[.creationDate] as? Date
        else { throw MacDiscoveryError.invalidIdentity }
        return
            "\(device.uint64Value):\(file.uint64Value):\(created.timeIntervalSinceReferenceDate.bitPattern)"
    }

    private static func record(_ entry: MacDiscoveryCapture, libraryID: UUID) -> SearchCapture {
        SearchCapture(
            reference: CaptureReference(libraryID: libraryID, captureID: entry.id),
            title: entry.title, keywords: entry.manualTags, revision: entry.revision)
    }
}
