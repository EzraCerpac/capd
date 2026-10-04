import CapdSync
import Foundation

public struct AutomaticSyncState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case setupRequired, idle, syncing, offline, retrying, paused, attention
    }
    public var phase: Phase = .paused
    public var pendingChanges = 0
    public var conflictCount = 0
    public var rejectedChanges = 0
    public var consecutiveFailures = 0
    public var nextRetryAt: Date?
    public var lastSuccessfulSync: Date?
    public var lastError: String?

    public init() {}
}

public protocol SyncSchedulerClock: Sendable {
    func now() async -> Date
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemSyncSchedulerClock: SyncSchedulerClock {
    public init() {}
    public func now() async -> Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

public struct AutomaticSyncPolicy: Sendable {
    public var debounce: TimeInterval
    public var foregroundPullInterval: TimeInterval
    public var initialRetry: TimeInterval
    public var maximumRetry: TimeInterval
    public var maximumFailures: Int

    public init(
        debounce: TimeInterval = 0.35, foregroundPullInterval: TimeInterval = 30,
        initialRetry: TimeInterval = 1, maximumRetry: TimeInterval = 30, maximumFailures: Int = 5
    ) {
        precondition(
            debounce >= 0 && foregroundPullInterval >= 0.25 && initialRetry > 0 && maximumRetry > 0
                && maximumFailures > 0)
        self.debounce = debounce
        self.foregroundPullInterval = foregroundPullInterval
        self.initialRetry = initialRetry
        self.maximumRetry = maximumRetry
        self.maximumFailures = maximumFailures
    }
}

public actor AutomaticSyncController {
    private enum TimerKind { case debounce, retry, poll, immediate }
    private let store: MobileStore
    private let coordinator: MobileSyncCoordinator
    private let clock: any SyncSchedulerClock
    private let policy: AutomaticSyncPolicy
    private let jitter: @Sendable () -> Double
    private var state = AutomaticSyncState()
    private var listeners: [UUID: AsyncStream<AutomaticSyncState>.Continuation] = [:]
    private var timer: Task<Void, Never>?
    private var timerID: UUID?
    private var timerKind: TimerKind?
    private var worker: Task<Void, Never>?
    private var active = false
    private var connected = true
    private var unconfigured = false
    private var halted = false
    private var needsPull = false

    public init(
        store: MobileStore, adapter: any MobileSyncAdapter = LocalOnlySyncAdapter(),
        clock: any SyncSchedulerClock = SystemSyncSchedulerClock(),
        policy: AutomaticSyncPolicy = AutomaticSyncPolicy(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }
    ) {
        self.store = store
        coordinator = MobileSyncCoordinator(store: store, adapter: adapter)
        self.clock = clock
        self.policy = policy
        self.jitter = jitter
    }

    public func states() -> AsyncStream<AutomaticSyncState> {
        let id = UUID()
        return AsyncStream { continuation in
            listeners[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) }
            }
        }
    }

    public func currentState() -> AutomaticSyncState { snapshot() }

    public func foreground() async {
        guard !active else { return }
        active = true
        unconfigured = false
        halted = false
        state.consecutiveFailures = 0
        needsPull = true
        await arm(after: 0, kind: .immediate)
    }

    public func suspend() {
        active = false
        cancelTimer()
        worker?.cancel()
        state.phase = .paused
        publish()
    }

    public func localChange() async {
        publish()
        guard active, connected, !unconfigured, !halted, worker == nil else { return }
        if timerKind == .retry { return }
        await arm(after: policy.debounce, kind: .debounce)
    }

    public func connectivityChanged(available: Bool) async {
        let changed = connected != available
        connected = available
        if !available {
            cancelTimer()
            worker?.cancel()
            if !unconfigured { state.phase = .offline }
            publish()
        } else if changed && active {
            halted = false
            state.consecutiveFailures = 0
            needsPull = true
            await arm(after: 0, kind: .immediate)
        }
    }

    public func retryNow() async {
        unconfigured = false
        halted = false
        state.consecutiveFailures = 0
        needsPull = true
        await arm(after: 0, kind: .immediate)
    }

    private func arm(after delay: TimeInterval, kind: TimerKind) async {
        guard active, connected, !unconfigured, !halted, worker == nil else {
            publish()
            return
        }
        cancelTimer()
        let id = UUID()
        timerID = id
        timerKind = kind
        if kind == .retry { state.nextRetryAt = await clock.now().addingTimeInterval(delay) }
        guard timerID == id, active, connected, worker == nil else { return }
        let clock = clock
        timer = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
                try Task.checkCancellation()
                await self?.timerFired(id)
            } catch {}
        }
        publish()
    }

    private func timerFired(_ id: UUID) {
        guard timerID == id, active, connected, !unconfigured, !halted, worker == nil else {
            return
        }
        timer = nil
        timerID = nil
        timerKind = nil
        state.nextRetryAt = nil
        needsPull = false
        state.phase = .syncing
        publish()
        let coordinator = coordinator
        worker = Task { [weak self] in
            let result: Result<SyncResult, any Error>
            do { result = .success(try await coordinator.sync()) } catch {
                result = .failure(error)
            }
            await self?.completed(result)
        }
    }

    private func completed(_ result: Result<SyncResult, any Error>) async {
        worker = nil
        guard active, connected else {
            state.phase = active ? .offline : .paused
            publish()
            return
        }
        switch result {
        case .success(.unconfigured):
            unconfigured = true
            state.phase = .setupRequired
            state.lastError = nil
            publish()
        case .success(.offline):
            state.phase = .offline
            publish()
        case .success(.sent):
            state.lastSuccessfulSync = await clock.now()
            guard active, connected else {
                state.phase = active ? .offline : .paused
                publish()
                return
            }
            state.lastError = nil
            state.consecutiveFailures = 0
            state.phase = .idle
            publish()
            if needsPull || state.pendingChanges > 0 {
                await arm(after: 0, kind: .immediate)
            } else {
                await arm(after: policy.foregroundPullInterval, kind: .poll)
            }
        case .failure(let error) where error is CancellationError:
            state.phase = needsPull || state.pendingChanges > 0 ? .retrying : .paused
            publish()
            if needsPull || state.pendingChanges > 0 {
                await arm(after: 0, kind: .immediate)
            } else {
                await arm(after: policy.foregroundPullInterval, kind: .poll)
            }
        case .failure(let error):
            state.lastError = error.localizedDescription
            state.consecutiveFailures += 1
            let transient =
                (error as? SyncError) == .transportDisconnected
                || (error as? SyncError) == .acknowledgementLost
                || (error as? SyncHTTPError) == .unavailable
            if !transient || state.consecutiveFailures >= policy.maximumFailures {
                halted = true
                state.phase = .attention
                publish()
            } else {
                state.phase = state.consecutiveFailures >= 3 ? .attention : .retrying
                let base = min(
                    policy.maximumRetry,
                    policy.initialRetry * pow(2, Double(state.consecutiveFailures - 1)))
                let delay = min(policy.maximumRetry, base * min(1.2, max(0.8, jitter())))
                await arm(after: delay, kind: .retry)
            }
        }
    }

    private func snapshot() -> AutomaticSyncState {
        var snapshot = state
        do {
            snapshot.pendingChanges = try store.pending().count
            snapshot.conflictCount = try store.search().filter { !$0.noteConflicts.isEmpty }.count
            snapshot.rejectedChanges = try store.rejectedWork().count
            if (snapshot.conflictCount > 0 || snapshot.rejectedChanges > 0)
                && snapshot.phase == .idle
            {
                snapshot.phase = .attention
            }
        } catch {
            snapshot.phase = .attention
            snapshot.lastError = error.localizedDescription
        }
        return snapshot
    }

    private func publish() {
        state = snapshot()
        for continuation in listeners.values { continuation.yield(state) }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerID = nil
        timerKind = nil
        state.nextRetryAt = nil
    }

    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
}
