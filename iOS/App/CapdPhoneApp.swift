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
    private var capturesByID: [UUID: MobileCapture] = [:]
    private var loadedLibraryRevision: MobileLibraryRevision?
    private var store: MobileStore?
    private var storeOpenError: Error?
    private var scheduler: AutomaticSyncController?
    private var stateTask: Task<Void, Never>?
    private var connectivity: SyncConnectivity?

    init(adapter: any MobileSyncAdapter = MobileEnvironment.adapter()) {
        do {
            store = try MobileEnvironment.store()
            if let store {
                let scheduler = AutomaticSyncController(
                    store: store, adapter: adapter, policy: MobileEnvironment.syncPolicy())
                self.scheduler = scheduler
                stateTask = Task { [weak self, scheduler] in
                    let stream = await scheduler.states()
                    await scheduler.foreground()
                    for await state in stream {
                        guard let self, !Task.isCancelled else { break }
                        self.syncState = state
                        if state.libraryRevision != self.loadedLibraryRevision { self.reload() }
                    }
                }
                connectivity = SyncConnectivity { [scheduler] available in
                    Task { await scheduler.connectivityChanged(available: available) }
                }
            }
            reload()
        } catch {
            storeOpenError = error
            self.error = error.localizedDescription
        }
    }

    func reload() {
        do {
            let revision = try store?.libraryRevision()
            let library = try store?.search() ?? []
            capturesByID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
            captures = query.isEmpty ? library : try store?.search(query) ?? []
            loadedLibraryRevision = revision
        } catch {
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
