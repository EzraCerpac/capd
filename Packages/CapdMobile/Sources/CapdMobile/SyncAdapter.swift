import CapdSync
import Foundation

public enum SyncAvailability: Equatable, Sendable { case unconfigured, offline, ready }

public protocol MobileSyncAdapter: Sendable {
    func availability() async -> SyncAvailability
    func transport() async -> (any SyncTransport)?
    func asyncConnection() async -> MobileAsyncSyncConnection?
}

extension MobileSyncAdapter {
    public func asyncConnection() async -> MobileAsyncSyncConnection? { nil }
}

public struct MobileAsyncSyncConnection: Sendable {
    public let transport: any AsyncSyncTransport
    public let credential: @Sendable () throws -> String

    public init(
        transport: any AsyncSyncTransport,
        credential: @escaping @Sendable () throws -> String
    ) {
        self.transport = transport
        self.credential = credential
    }
}

/// Prepared adapter; activation stays gated until library migration and cutover are accepted.
public struct EnrolledSyncAdapter: MobileSyncAdapter {
    private let connection: MobileAsyncSyncConnection

    public init(enrollment: SyncEnrollment, credentials: any SyncCredentialStore) throws {
        try SyncEnrollmentActivation.requireReady()
        connection = MobileAsyncSyncConnection(
            transport: try URLSessionSyncTransport(
                endpoint: enrollment.endpoint, binding: enrollment.binding,
                deviceID: enrollment.deviceID),
            credential: { try credentials.read(for: enrollment) })
    }

    public func availability() async -> SyncAvailability { .ready }
    public func transport() async -> (any SyncTransport)? { nil }
    public func asyncConnection() async -> MobileAsyncSyncConnection? { connection }
}

public struct LocalOnlySyncAdapter: MobileSyncAdapter {
    public init() {}
    public func availability() async -> SyncAvailability { .unconfigured }
    public func transport() async -> (any SyncTransport)? { nil }
}

public struct ReferenceSyncAdapter: MobileSyncAdapter {
    private let reference: ReferenceTransport
    public init(port: UInt16) { reference = ReferenceTransport(port: port) }
    public func availability() async -> SyncAvailability { .ready }
    public func transport() async -> (any SyncTransport)? { reference }
}

public enum SyncResult: Equatable, Sendable {
    case unconfigured, offline
    case sent(Int, rejected: Int)
}

public actor MobileSyncCoordinator {
    private let store: MobileStore
    private let adapter: any MobileSyncAdapter
    private var flight: (id: UUID, pullOnly: Bool, task: Task<SyncResult, any Error>)?

    public init(store: MobileStore, adapter: any MobileSyncAdapter = LocalOnlySyncAdapter()) {
        self.store = store
        self.adapter = adapter
    }

    public func sync() async throws -> SyncResult { try await run(pullOnly: false) }
    public func refresh() async throws { _ = try await run(pullOnly: true) }
    public func cancel() { flight?.task.cancel() }

    private func run(pullOnly: Bool) async throws -> SyncResult {
        try Task.checkCancellation()
        while let current = flight {
            if current.pullOnly == pullOnly { return try await wait(for: current.task) }
            // Opposite modes share exclusive access, not the earlier operation's result.
            do { _ = try await wait(for: current.task) } catch {}
            try Task.checkCancellation()
            if flight?.id == current.id { flight = nil }
        }
        let id = UUID()
        let store = store
        let adapter = adapter
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            switch await adapter.availability() {
            case .unconfigured: return SyncResult.unconfigured
            case .offline: return SyncResult.offline
            case .ready: break
            }
            try Task.checkCancellation()
            let receipts: [SyncReceipt]
            if let connection = await adapter.asyncConnection() {
                try await store.pull(from: connection.transport, credential: connection.credential)
                receipts =
                    pullOnly
                    ? []
                    : try await store.push(
                        to: connection.transport, credential: connection.credential)
                try Task.checkCancellation()
                try await store.pull(from: connection.transport, credential: connection.credential)
            } else if let transport = await adapter.transport() {
                try store.pull(from: transport)
                receipts = pullOnly ? [] : try store.push(to: transport)
                try Task.checkCancellation()
                try store.pull(from: transport)
            } else {
                return SyncResult.unconfigured
            }
            let sent = receipts.filter { $0.outcome == .accepted || $0.outcome == .noteConflict }
                .count
            return SyncResult.sent(sent, rejected: receipts.count - sent)
        }
        flight = (id, pullOnly, task)
        defer { if flight?.id == id { flight = nil } }
        return try await wait(for: task)
    }

    private func wait(for task: Task<SyncResult, any Error>) async throws -> SyncResult {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
