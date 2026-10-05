import CapdSync
import Foundation
import Synchronization

public struct MacNoteConflict: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let revision: Int64
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
    public var websiteIconIssue: String?
    /// True only when this returned sync cycle successfully drained the remote feed.
    public var pullSucceeded = false
    public static let localOnly = MacSyncStatus(
        phase: .unconfigured, pending: 0, rejected: 0, cursor: 0)
}

public actor MacSyncRuntime {
    private let store: Store
    private let configuration: MacSyncConfiguration
    private let transport: any AsyncSyncTransport
    private let credential: @Sendable () throws -> String
    private struct Flight: Sendable {
        let id: UUID
        let task: Task<MacSyncStatus, Never>
        let waiters: MacSyncWaiters
    }
    private var flight: Flight?
    private var polling: Task<Void, Never>?
    private var phase: MacSyncStatus.Phase = .idle
    private var issue: String?
    private var websiteIconIssue: String?

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
        Self.snapshot(
            store: store, phase: phase, issue: issue, websiteIconIssue: websiteIconIssue)
    }

    @discardableResult
    public func sync() async -> MacSyncStatus {
        let waiterID = UUID()
        if let flight {
            flight.waiters.register(waiterID)
            return await wait(flight, waiterID: waiterID)
        }
        let id = UUID()
        let waiters = MacSyncWaiters(owner: waiterID)
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
                var iconIssue: String?
                do {
                    try await client.pushWebsiteIcons(to: transport, credential: credential)
                    for _ in 0..<8 {
                        try Task.checkCancellation()
                        let cursor = try client.websiteIconCursor()
                        try await client.pullWebsiteIcons(from: transport, credential: credential)
                        if try client.websiteIconCursor() == cursor { break }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    iconIssue = (error as? SyncHTTPError) == .unsupportedVersion
                        ? "This server needs an update to sync website icons. Saved captures still sync."
                        : "Website icons could not finish syncing. Cached icons remain available."
                }
                do { try store.refreshWebsiteIconsFromSync() } catch {
                    iconIssue = "A website icon could not be verified. Saved captures still sync."
                }
                try Task.checkCancellation()
                return Self.snapshot(
                    store: store, phase: .idle, pullSucceeded: true, websiteIconIssue: iconIssue)
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
        let running = Flight(id: id, task: task, waiters: waiters)
        flight = running
        Task.detached { [weak self] in
            let result = await task.value
            waiters.complete(result)
            await self?.finish(id: id, result: result)
        }
        return await wait(running, waiterID: waiterID)
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
        let timeoutIssue = "Sync timed out. Saved changes remain queued."
        if flight == nil {
            phase = .attention
            issue = timeoutIssue
        }
        return Self.snapshot(store: store, phase: .attention, issue: timeoutIssue)
    }

    public func stop() async {
        polling?.cancel()
        polling = nil
        let running = flight
        running?.task.cancel()
        _ = await running?.task.value
        if flight == nil || flight?.id == running?.id {
            flight = nil
            phase = .paused
        }
    }

    private func finish(id: UUID, result: MacSyncStatus) {
        guard flight?.id == id else { return }
        flight = nil
        phase = result.phase
        issue = result.issue
        websiteIconIssue = result.websiteIconIssue
    }

    private func wait(_ running: Flight, waiterID: UUID) async -> MacSyncStatus {
        switch await running.waiters.wait(waiterID, task: running.task) {
        case .completed(let result):
            finish(id: running.id, result: result)
            return result
        case .cancelled(let exclusive):
            if exclusive {
                let result = await running.task.value
                finish(id: running.id, result: result)
                return result
            }
            return Self.snapshot(
                store: store, phase: .paused,
                issue: "Sync was cancelled. Saved changes remain queued.")
        }
    }

    static func snapshot(
        store: Store, phase: MacSyncStatus.Phase, issue: String? = nil, pullSucceeded: Bool = false,
        websiteIconIssue: String? = nil
    )
        -> MacSyncStatus
    {
        guard let client = store.syncClient else {
            return MacSyncStatus(phase: .unconfigured, pending: 0, rejected: 0, cursor: 0)
        }
        do {
            let pending = try client.pendingOperations().count
            let rejected = try client.rejectedWork().count
            let conflicts = try store.noteConflicts()
            var result = MacSyncStatus(
                phase: !conflicts.isEmpty || (phase == .idle && rejected > 0) ? .attention : phase,
                pending: pending, rejected: rejected, cursor: try client.cursor(),
                noteConflicts: conflicts,
                issue: issue
                    ?? (!conflicts.isEmpty ? "Conflicting notes need review." : nil)
                    ?? (rejected > 0 ? "Some saved changes were rejected and need attention." : nil)
            )
            result.pullSucceeded = pullSucceeded
            result.websiteIconIssue = websiteIconIssue
            return result
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

private final class MacSyncWaiters: Sendable {
    enum Outcome: Sendable {
        case completed(MacSyncStatus)
        case cancelled(exclusive: Bool)
    }
    private enum Waiter: Sendable {
        case waiting(CheckedContinuation<Outcome, Never>?)
        case cancelled(exclusive: Bool)
    }
    private struct State: Sendable {
        var result: MacSyncStatus?
        var waiters: [UUID: Waiter] = [:]
    }
    private let owner: UUID
    private let state: Mutex<State>

    init(owner: UUID) {
        self.owner = owner
        state = Mutex(State(waiters: [owner: .waiting(nil)]))
    }

    func register(_ id: UUID) {
        state.withLock { $0.waiters[id] = .waiting(nil) }
    }

    func wait(_ id: UUID, task: Task<MacSyncStatus, Never>) async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let outcome = state.withLock { state -> Outcome? in
                    if case .cancelled(let exclusive)? = state.waiters[id] {
                        state.waiters.removeValue(forKey: id)
                        return .cancelled(exclusive: exclusive)
                    }
                    if let result = state.result {
                        state.waiters.removeValue(forKey: id)
                        return .completed(result)
                    }
                    state.waiters[id] = .waiting(continuation)
                    return nil
                }
                if let outcome { continuation.resume(returning: outcome) }
            }
        } onCancel: {
            let cancelled = state.withLock {
                state -> (CheckedContinuation<Outcome, Never>?, Bool) in
                guard state.result == nil, case .waiting(let continuation)? = state.waiters[id]
                else {
                    return (nil, false)
                }
                let waitingCount = state.waiters.values.reduce(0) { count, waiter in
                    if case .waiting = waiter { return count + 1 }
                    return count
                }
                let exclusive = id == owner && waitingCount == 1
                if continuation != nil {
                    state.waiters.removeValue(forKey: id)
                } else {
                    state.waiters[id] = .cancelled(exclusive: exclusive)
                }
                return (continuation, exclusive)
            }
            if cancelled.1 { task.cancel() }
            cancelled.0?.resume(returning: .cancelled(exclusive: cancelled.1))
        }
    }

    func complete(_ result: MacSyncStatus) {
        let continuations = state.withLock { state in
            state.result = result
            var continuations: [CheckedContinuation<Outcome, Never>] = []
            for (id, waiter) in state.waiters {
                if case .waiting(let continuation) = waiter, let continuation {
                    continuations.append(continuation)
                    state.waiters.removeValue(forKey: id)
                }
            }
            return continuations
        }
        for continuation in continuations { continuation.resume(returning: .completed(result)) }
    }
}
