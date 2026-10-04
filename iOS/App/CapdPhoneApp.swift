import CapdMobile
import SwiftUI

@main
struct CapdPhoneApp: App {
    var body: some Scene {
        WindowGroup { LibraryView() }
    }
}

@MainActor
@Observable
final class LibraryModel {
    var captures: [MobileCapture] = []
    var query = ""
    var error: String?
    var syncState = AutomaticSyncState()
    var showSetupHint = !UserDefaults.standard.bool(forKey: "capd.sync-setup-explanation-seen")
    private(set) var connection: PhoneLibraryConnection?
    private(set) var librarySession: MobileLibrarySession?
    private var capturesByID: [UUID: MobileCapture] = [:]
    private var loadedLibraryRevision: MobileLibraryRevision?
    private var store: MobileStore?
    private var storeOpenError: Error?
    private var scheduler: AutomaticSyncController?
    private var stateTask: Task<Void, Never>?
    private var connectivity: SyncConnectivity?
    private let adapterOverride: (any MobileSyncAdapter)?
    private var changingLibrary = false
    private var sceneIsActive = true

    init(adapter: (any MobileSyncAdapter)? = nil) {
        adapterOverride = adapter ?? MobileEnvironment.syntheticAdapter()
        do {
            try openSelectedSession()
            connection = PhoneLibraryConnection(
                root: try MobileEnvironment.root(),
                credentials: MobileEnvironment.credentials,
                beforeTransition: { [weak self] in await self?.pauseForTransition() },
                afterTransition: { [weak self] in await self?.finishTransition() })
            reload()
            #if DEBUG
                Task { await connection?.runRequestedPreparation() }
            #endif
        } catch {
            storeOpenError = error
            self.error = error.localizedDescription
        }
    }

    private func openSelectedSession() throws {
        let session = try MobileEnvironment.session(role: .app)
        librarySession = session
        store = session.store
        if let store {
            let scheduler = AutomaticSyncController(
                store: store, adapter: adapterOverride ?? session.adapter,
                policy: MobileEnvironment.syncPolicy())
            self.scheduler = scheduler
            stateTask = Task { [weak self, scheduler] in
                let stream = await scheduler.states()
                guard !Task.isCancelled, self?.changingLibrary == false,
                    self?.scheduler === scheduler
                else { return }
                if self?.sceneIsActive == true && !MobileEnvironment.holdsSyntheticOfflineWork {
                    await scheduler.foreground()
                }
                for await state in stream {
                    guard let self, !Task.isCancelled, self.scheduler === scheduler else { break }
                    guard !self.changingLibrary else { continue }
                    self.syncState = state
                    if state.libraryRevision != self.loadedLibraryRevision { self.reload() }
                }
            }
            if !MobileEnvironment.holdsSyntheticOfflineWork {
                connectivity = SyncConnectivity { [scheduler] available in
                    Task { await scheduler.connectivityChanged(available: available) }
                }
            }
        }
        storeOpenError = nil
    }

    private func pauseForTransition() async {
        changingLibrary = true
        let previousStateTask = stateTask
        stateTask = nil
        previousStateTask?.cancel()
        connectivity = nil
        await previousStateTask?.value
        await scheduler?.suspendAndDrain()
    }

    private func finishTransition() async {
        do {
            try openSelectedSession()
            changingLibrary = false
            reload()
        } catch {
            changingLibrary = false
            storeOpenError = error
            self.error = error.localizedDescription
        }
    }

    func reload() {
        guard !changingLibrary else { return }
        do {
            let revision = try store?.libraryRevision()
            let library = try store?.search() ?? []
            capturesByID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
            captures = query.isEmpty ? library : try store?.search(query) ?? []
            loadedLibraryRevision = revision
        } catch {
            if error as? MobileActivationError == .sessionReplaced {
                Task {
                    await pauseForTransition()
                    await finishTransition()
                }
                return
            }
            self.error = "Could not refresh the saved library. \(error.localizedDescription)"
        }
    }

    func capture(id: UUID) -> MobileCapture? {
        capturesByID[id] ?? (try? store?.capture(id: id))
    }

    func update(capture: MobileCapture, note: String, tags: [String], resolving: [UUID]) -> Bool {
        do {
            guard let store else {
                throw MobileEnvironment.EnvironmentError.sharedContainerUnavailable
            }
            try store.update(capture, note: note, tags: tags, resolving: resolving)
            reload()
            changedLocally()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func delete(id: UUID) -> Bool {
        do {
            guard let store else {
                throw MobileEnvironment.EnvironmentError.sharedContainerUnavailable
            }
            try store.delete(id: id)
            reload()
            changedLocally()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func sceneChanged(active: Bool) {
        sceneIsActive = active
        guard !MobileEnvironment.holdsSyntheticOfflineWork else { return }
        guard !changingLibrary else { return }
        guard let scheduler else { return }
        if active {
            reload()
            Task { await scheduler.foreground() }
        } else {
            Task { await scheduler.suspend() }
        }
    }

    func dismissSetupHint() {
        showSetupHint = false
        UserDefaults.standard.set(true, forKey: "capd.sync-setup-explanation-seen")
    }

    func retrySync() { Task { await scheduler?.retryNow() } }

    private func changedLocally() { Task { await scheduler?.localChange() } }

    isolated deinit {
        stateTask?.cancel()
        let scheduler = scheduler
        Task { await scheduler?.suspend() }
    }

    func save(text: String, title: String, note: String, isLink: Bool) -> Bool {
        do {
            guard let store else {
                throw storeOpenError
                    ?? MobileEnvironment.EnvironmentError.sharedContainerUnavailable
            }
            try store.save(CaptureInput.make(text: text, title: title, note: note, isLink: isLink))
            reload()
            changedLocally()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
