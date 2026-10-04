import CapdSync
import Foundation

public struct MacNoteConflict: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let variants: [NoteVariant]
}

public struct MacSyncStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case unconfigured, paused, idle, syncing, busy, offline, attention
    }
    public var phase: Phase
    public var pending: Int
    public var rejected: Int
    public var cursor: Int64
    public var noteConflicts: [MacNoteConflict] = []
    public var issue: String?
    public static let localOnly = MacSyncStatus(
        phase: .unconfigured, pending: 0, rejected: 0, cursor: 0)
}

public actor MacSyncRuntime {
    private let store: Store
    private let configuration: MacSyncConfiguration
    private let transport: any AsyncSyncTransport
    private let credential: @Sendable () throws -> String
    private var flight: (id: UUID, task: Task<MacSyncStatus, Never>)?
    private var polling: Task<Void, Never>?
    private var phase: MacSyncStatus.Phase = .idle
    private var issue: String?

    init(
        store: Store, configuration: MacSyncConfiguration,
        transport: any AsyncSyncTransport, credential: @escaping @Sendable () throws -> String,
        initialIssue: String? = nil
    ) {
        self.store = store
        self.configuration = configuration
        self.transport = transport
        self.credential = credential
        phase = !configuration.enabled ? .paused : initialIssue == nil ? .idle : .attention
        issue = initialIssue
    }

    public func status() -> MacSyncStatus {
        Self.snapshot(store: store, phase: phase, issue: issue)
    }

    @discardableResult
    public func sync() async -> MacSyncStatus {
        if let flight { return await wait(flight.task) }
        let id = UUID()
        let store = store
        let configuration = configuration
        let transport = transport
        let credential = credential
        phase = .syncing
        let task = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                guard let lease = try MacSyncLease.acquire(paths: store.paths) else {
                    return Self.snapshot(store: store, phase: .busy)
                }
                defer { withExtendedLifetime(lease) {} }
                guard let current = try MacSyncConfiguration.load(paths: store.paths),
                    current.endpoint == configuration.endpoint,
                    current.binding == configuration.binding,
                    current.deviceID == configuration.deviceID,
                    current.loopbackSOCKSPort == configuration.loopbackSOCKSPort
                else { throw MacSyncError.configurationChanged }
                guard current.enabled else { return Self.snapshot(store: store, phase: .paused) }
                guard let client = store.syncClient else {
                    throw MacSyncError.configurationRequired
                }
                // Upload local creates before pull can project an as-yet-unconfirmed duplicate.
                _ = try await client.push(to: transport, credential: credential)
                while true {
                    let cursor = try client.cursor()
                    try await client.pull(from: transport, credential: credential)
                    if try client.cursor() == cursor { break }
                }
                try Task.checkCancellation()
                return Self.snapshot(store: store, phase: .idle)
            } catch is CancellationError {
                return Self.snapshot(
                    store: store, phase: .paused,
                    issue: "Sync was cancelled. Saved changes remain queued.")
            } catch {
                return Self.snapshot(
                    store: store, phase: Self.isOffline(error) ? .offline : .attention,
                    issue: Self.message(error))
            }
        }
        flight = (id, task)
        let result = await wait(task)
        if flight?.id == id {
            flight = nil
            phase = result.phase
            issue = result.issue
        }
        return result
    }

    public func start(interval: Duration = .seconds(5)) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let result = await self.sync()
                do {
                    try await Task.sleep(
                        for: result.phase == .offline || result.phase == .attention
                            ? .seconds(30) : interval)
                } catch { return }
            }
        }
    }

    public func sync(within timeout: Duration) async -> MacSyncStatus {
        let completed = await withTaskGroup(of: MacSyncStatus?.self) { group in
            group.addTask { await self.sync() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
        if let completed { return completed }
        phase = .attention
        issue = "Sync timed out. Saved changes remain queued."
        return status()
    }

    public func stop() async {
        polling?.cancel()
        polling = nil
        let running = flight?.task
        running?.cancel()
        _ = await running?.value
        phase = .paused
    }

    private func wait(_ task: Task<MacSyncStatus, Never>) async -> MacSyncStatus {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func snapshot(store: Store, phase: MacSyncStatus.Phase, issue: String? = nil)
        -> MacSyncStatus
    {
        guard let client = store.syncClient else {
            return MacSyncStatus(phase: .unconfigured, pending: 0, rejected: 0, cursor: 0)
        }
        do {
            let pending = try client.pendingOperations().count
            let rejected = try client.rejectedWork().count
            let conflicts = try store.noteConflicts()
            return MacSyncStatus(
                phase: !conflicts.isEmpty || (phase == .idle && rejected > 0) ? .attention : phase,
                pending: pending, rejected: rejected, cursor: try client.cursor(),
                noteConflicts: conflicts,
                issue: issue
                    ?? (!conflicts.isEmpty ? "Conflicting notes need review." : nil)
                    ?? (rejected > 0 ? "Some saved changes were rejected and need attention." : nil)
            )
        } catch {
            return MacSyncStatus(
                phase: .attention, pending: 0, rejected: 0, cursor: 0,
                issue: "The configured library is unavailable.")
        }
    }

    private static func isOffline(_ error: any Error) -> Bool {
        (error as? SyncError) == .transportDisconnected || (error as? SyncHTTPError) == .unavailable
    }

    private static func message(_ error: any Error) -> String {
        if error is SyncConnectionError || error is SyncHTTPError || error is MacSyncError {
            return (error as? LocalizedError)?.errorDescription
                ?? "Sync needs attention. Saved changes remain queued."
        }
        return "Sync could not finish. Saved changes remain queued."
    }
}
