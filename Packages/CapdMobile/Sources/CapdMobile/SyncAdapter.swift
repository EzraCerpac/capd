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

    /// Only a factory-selected, already bound store may enable enrolled sync.
    init(
        enrollment: SyncEnrollment, store: MobileStore,
        credentials: any SyncCredentialStore
    ) throws {
        guard store.libraryBinding == enrollment.binding, store.deviceID == enrollment.deviceID
        else { throw SyncBindingError.mismatch }
        connection = MobileAsyncSyncConnection(
            transport: try URLSessionSyncTransport(
                endpoint: enrollment.endpoint,
                binding: enrollment.binding, deviceID: enrollment.deviceID),
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
    case sent(Int, rejected: Int, websiteIconIssue: WebsiteIconSyncIssue? = nil)
}

public enum WebsiteIconSyncIssue: String, Codable, Equatable, Sendable {
    case unsupportedServer, unavailable, invalidData

    public var detail: String {
        switch self {
        case .unsupportedServer:
            "This server needs an update to sync website icons. Saved captures still sync."
        case .unavailable:
            "Website icons will retry when the connection is available. Cached icons remain available."
        case .invalidData:
            "A website icon could not be verified. Saved captures still sync."
        }
    }

    public init(error: any Error) {
        if (error as? SyncHTTPError) == .unsupportedVersion {
            self = .unsupportedServer
        } else if (error as? SyncError) == .transportDisconnected
            || (error as? SyncError) == .acknowledgementLost
            || (error as? SyncHTTPError) == .unavailable
        {
            self = .unavailable
        } else {
            self = .invalidData
        }
    }
}

public actor MobileSyncCoordinator {
    private let store: MobileStore
    private let adapter: any MobileSyncAdapter
    private var flight: (id: UUID, pullOnly: Bool, task: Task<SyncResult, any Error>)?
    private var draining = false
    private var flightGeneration = UUID()

    public init(store: MobileStore, adapter: any MobileSyncAdapter = LocalOnlySyncAdapter()) {
        self.store = store
        self.adapter = adapter
    }

    public func sync() async throws -> SyncResult { try await run(pullOnly: false) }
    public func refresh() async throws { _ = try await run(pullOnly: true) }
    public func cancel() { flight?.task.cancel() }

    public func cancelAndDrain() async {
        draining = true
        flightGeneration = UUID()
        let running = flight
        running?.task.cancel()
        _ = try? await running?.task.value
        if flight?.id == running?.id { flight = nil }
        draining = false
    }

    private func run(pullOnly: Bool) async throws -> SyncResult {
        guard !draining else { throw CancellationError() }
        let generation = flightGeneration
        try Task.checkCancellation()
        while let current = flight {
            if current.pullOnly == pullOnly { return try await join(current.task) }
            // Opposite modes share exclusive access, not the earlier operation's result.
            do { _ = try await join(current.task) } catch {}
            try Task.checkCancellation()
            guard !draining, generation == flightGeneration else { throw CancellationError() }
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
            var iconIssue: WebsiteIconSyncIssue?
            if let connection = await adapter.asyncConnection() {
                do {
                    try await store.pull(
                        from: connection.transport, credential: connection.credential)
                } catch SyncError.recoverySequenceCollision where !pullOnly {}
                receipts =
                    pullOnly
                    ? []
                    : try await store.push(
                        to: connection.transport, credential: connection.credential)
                try Task.checkCancellation()
                try await store.pull(from: connection.transport, credential: connection.credential)
                do {
                    try await store.pullWebsiteIcons(
                        from: connection.transport, credential: connection.credential)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    iconIssue = WebsiteIconSyncIssue(error: error)
                }
            } else if let transport = await adapter.transport() {
                do {
                    try store.pull(from: transport)
                } catch SyncError.recoverySequenceCollision where !pullOnly {}
                receipts = pullOnly ? [] : try store.push(to: transport)
                try Task.checkCancellation()
                try store.pull(from: transport)
                if let icons = transport as? any WebsiteIconSyncTransport {
                    do {
                        try store.pullWebsiteIcons(from: icons)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        iconIssue = WebsiteIconSyncIssue(error: error)
                    }
                }
            } else {
                return SyncResult.unconfigured
            }
            let sent = receipts.filter { $0.outcome == .accepted || $0.outcome == .noteConflict }
                .count
            try Task.checkCancellation()
            return SyncResult.sent(
                sent, rejected: receipts.count - sent, websiteIconIssue: iconIssue)
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

    private func join(_ task: Task<SyncResult, any Error>) async throws -> SyncResult {
        let waiter = FlightWaiter()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task { waiter.finish(await task.result) }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }
}

private final class FlightWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SyncResult, any Error>?
    private var result: Result<SyncResult, any Error>?

    func install(_ continuation: CheckedContinuation<SyncResult, any Error>) {
        let completed: Result<SyncResult, any Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    func finish(_ result: Result<SyncResult, any Error>) {
        let waiting: CheckedContinuation<SyncResult, any Error>? = lock.withLock {
            guard self.result == nil else {
                return nil
            }
            self.result = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
