import CapdMobile
import CapdSync
import CapdSystemIntegration
import Foundation
import Observation

@MainActor
@Observable
final class PhoneSystemSearch {
    private(set) var enabled: Bool
    private(set) var updating = false
    private(set) var error: String?
    private var bridge: CaptureSystemBridge?
    private var coordinator: SpotlightCoordinator?
    private var tail: Task<Void, Never>?
    private var session: MobileLibrarySession?
    private var preparedLibraryID: UUID?
    private var preparedSessionToken: MobileLibrarySessionToken?
    private var preparedRevision: MobileLibraryRevision?
    private var generation = 0
    private var paused = false
    private let defaults: UserDefaults
    private let localID: UUID

    init() {
        let defaults = UserDefaults(suiteName: MobileEnvironment.groupID) ?? .standard
        self.defaults = defaults
        enabled = defaults.bool(forKey: "capd.system-search.enabled")
        if let stored = defaults.string(forKey: "capd.system-search.local-library-id"),
            let id = UUID(uuidString: stored)
        {
            localID = id
        } else {
            localID = UUID()
            defaults.set(localID.uuidString, forKey: "capd.system-search.local-library-id")
        }
    }

    func connect(_ bridge: CaptureSystemBridge) {
        self.bridge = bridge
        if !enabled { invalidate(bridge) }
        schedule()
    }

    func refresh(session: MobileLibrarySession) {
        self.session = session
        paused = false
        schedule()
    }

    func resumeWithoutSession() {
        session = nil
        preparedLibraryID = nil
        preparedSessionToken = nil
        preparedRevision = nil
        coordinator = nil
        paused = false
        if let bridge { invalidate(bridge) }
        schedule()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "capd.system-search.enabled")
        if !value, let bridge { invalidate(bridge) }
        schedule()
    }

    func retry() { schedule() }

    func prepareForIntent() async throws {
        guard session != nil, bridge != nil, !paused else {
            throw SystemIntegrationError.unavailable
        }
        try Task.checkCancellation()
        while true {
            let generation = generation
            await tail?.value
            try Task.checkCancellation()
            guard !paused else { throw SystemIntegrationError.unavailable }
            guard generation == self.generation else { continue }
            guard error == nil else { throw SystemIntegrationError.unavailable }
            if enabled, let session {
                let revision = try session.store.libraryRevision()
                if preparedSessionToken != session.token || preparedRevision != revision {
                    schedule()
                    continue
                }
            }
            break
        }
    }

    func suspendAndDrain() async {
        paused = true
        if let bridge { invalidate(bridge) }
        // OS callbacks are not cancellable: retain the lease until they complete.
        await tail?.value
    }

    private func schedule() {
        guard let bridge, !paused else { return }
        let session = session
        let previous = tail
        generation += 1
        let generation = generation
        updating = true
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer { if self.generation == generation { self.updating = false } }
            guard !self.paused else { return }
            do {
                if let session, self.enabled {
                    try await session.withSystemSearchLease { @MainActor in
                        do {
                            try await self.reconcile(session: session, bridge: bridge)
                        } catch {
                            self.invalidate(
                                bridge, preservingDeferredRoute: self.enabled && !self.paused)
                            _ = try await self.cleanup(keeping: nil, bridge: bridge)
                            throw error
                        }
                    }
                } else {
                    try await MobileSystemSearchJournal.withLease(root: MobileEnvironment.root()) {
                        @MainActor in
                        self.invalidate(
                            bridge, preservingDeferredRoute: self.enabled && !self.paused)
                        _ = try await self.cleanup(keeping: nil, bridge: bridge)
                    }
                }
                self.error = nil
            } catch {
                self.invalidate(bridge, preservingDeferredRoute: self.enabled && !self.paused)
                self.coordinator = nil
                self.error = "System search could not update. " + error.localizedDescription
            }
        }
    }

    private func reconcile(session: MobileLibrarySession, bridge: CaptureSystemBridge) async throws
    {
        let libraryID = session.token.binding?.libraryID ?? localID
        let journal = try await cleanup(keeping: enabled ? libraryID : nil, bridge: bridge)
        if preparedLibraryID != libraryID || preparedSessionToken != session.token {
            invalidate(bridge, preservingDeferredRoute: true)
            coordinator = nil
            preparedLibraryID = libraryID
            preparedSessionToken = session.token
        }
        let revision = try session.store.libraryRevision()
        let snapshot = try session.store.systemSearchDiscoverySnapshot()
        let captures = snapshot.captures.map {
            PhoneSearchProjection.capture($0, libraryID: libraryID)
        }
        if enabled {
            guard !snapshot.exceedsLimit else {
                try journal.begin(libraryID)
                let index =
                    coordinator
                    ?? SpotlightCoordinator(
                        libraryID: libraryID, backend: backend())
                invalidate(bridge, preservingDeferredRoute: enabled && !paused)
                try await index.reconcile([], enabled: false)
                try journal.removed(libraryID)
                coordinator = nil
                throw SystemIntegrationError.snapshotTooLarge
            }
            try journal.begin(libraryID)
            if coordinator == nil {
                coordinator = SpotlightCoordinator(libraryID: libraryID, backend: backend())
            }
            try await coordinator?.reconcile(captures, enabled: true)
            if !enabled || paused {
                try await coordinator?.reconcile([], enabled: false)
                try journal.removed(libraryID)
                invalidate(bridge)
                coordinator = nil
            }
        }
        try session.store.acknowledgeSystemSearch(snapshot.revision)
        if enabled && !paused {
            try bridge.refresh(
                libraryID: libraryID, captures: captures, systemSearchEnabled: true)
        } else if !enabled {
            try bridge.refresh(libraryID: libraryID, captures: [], systemSearchEnabled: false)
        }
        preparedRevision = revision
    }

    private func cleanup(keeping libraryID: UUID?, bridge: CaptureSystemBridge) async throws
        -> MobileSystemSearchJournal
    {
        let journal = MobileSystemSearchJournal(root: try MobileEnvironment.root())
        if let previous = defaults.string(forKey: "capd.system-search.indexed-library-id")
            .flatMap(UUID.init(uuidString:))
        {
            try journal.begin(previous)
            defaults.removeObject(forKey: "capd.system-search.indexed-library-id")
        }
        for oldID in try journal.libraries() where oldID != libraryID {
            invalidate(bridge, preservingDeferredRoute: enabled && !paused)
            let old = SpotlightCoordinator(libraryID: oldID, backend: backend())
            try await old.reconcile([], enabled: false)
            try journal.removed(oldID)
            coordinator = nil
        }
        return journal
    }

    private func invalidate(
        _ bridge: CaptureSystemBridge, preservingDeferredRoute: Bool = false
    ) {
        bridge.invalidate(preservingDeferredRoute: enabled && preservingDeferredRoute)
        if !enabled {
            do {
                try bridge.refresh(
                    libraryID: session?.token.binding?.libraryID ?? localID,
                    captures: [], systemSearchEnabled: false)
            } catch {
                self.error = "System search could not update. " + error.localizedDescription
            }
        }
    }

    private func backend() -> CoreSpotlightBackend {
        CoreSpotlightBackend(name: "dev.jxd.capd.phone.captures")
    }
}
