import Foundation

public enum SpotlightDonationOutcome: Equatable, Sendable {
    case indexed
    case deferred
    case cancelled
    case failed
}

/// Donates one canonical saved record without resetting a library domain.
/// The caller supplies the active session check and durable, token-specific repair journal.
/// A deadline releases the caller; Core Spotlight may still finish its underlying write.
/// App/extension callers must serialize journal ownership and deletion with other index writers.
@MainActor
public final class SpotlightDonation {
    private static var pending: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private let backend: any SpotlightBackend
    private let namespace: String

    public init(
        backend: any SpotlightBackend, namespace: String = "dev.jxd.capd.captures"
    ) {
        self.backend = backend
        self.namespace = namespace
    }

    public func donate(
        _ capture: SearchCapture,
        deadline: Duration = .seconds(1),
        isAuthorized: @escaping @MainActor () -> Bool,
        beginRepair: @escaping @MainActor (UUID, CaptureReference) throws -> Void,
        finishRepair: @escaping @MainActor (UUID) throws -> Void,
        ownsRepair: @escaping @MainActor (UUID, CaptureReference) -> Bool,
        cleanupIfOwned:
            @escaping @MainActor (
                UUID, CaptureReference, @MainActor () async throws -> Void
            ) async throws -> Bool
    ) async -> SpotlightDonationOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard deadline > .zero, capture.isBounded, !capture.deleted, capture.text.isEmpty,
            isAuthorized()
        else {
            return .deferred
        }
        let domain = "\(namespace).\(capture.reference.libraryID.uuidString.lowercased())"
        let repairID = UUID()
        let queueKey = "\(domain)/\(capture.id)"
        let predecessor = Self.pending[queueKey]?.task
        let state = DonationWait()
        let backend = backend
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)
                guard !state.finished else { return }
                state.operation = Task { @MainActor in
                    await predecessor?.value
                    defer {
                        if Self.pending[queueKey]?.token == repairID {
                            Self.pending.removeValue(forKey: queueKey)
                        }
                    }
                    var writeStarted = false
                    var journalStarted = false
                    do {
                        try Task.checkCancellation()
                        guard isAuthorized() else {
                            state.finish(.deferred)
                            return
                        }
                        try beginRepair(repairID, capture.reference)
                        journalStarted = true
                        writeStarted = true
                        try await backend.replace([capture], domain: domain)
                        if !Task.isCancelled && !state.finished && isAuthorized()
                            && ownsRepair(repairID, capture.reference)
                        {
                            try finishRepair(repairID)
                            state.finish(.indexed)
                        } else {
                            if try await cleanupIfOwned(
                                repairID, capture.reference,
                                {
                                    try await backend.delete(identifiers: [capture.id])
                                })
                            {
                                try finishRepair(repairID)
                            }
                            state.finish(Task.isCancelled ? .cancelled : .deferred)
                        }
                    } catch {
                        // A callback error can follow a partially accepted write. Keep the
                        // journal unless the exact identifier has been removed successfully.
                        do {
                            if writeStarted {
                                guard
                                    try await cleanupIfOwned(
                                        repairID, capture.reference,
                                        {
                                            try await backend.delete(identifiers: [capture.id])
                                        })
                                else {
                                    state.finish(Task.isCancelled ? .cancelled : .failed)
                                    return
                                }
                            }
                            if journalStarted { try finishRepair(repairID) }
                        } catch {}
                        state.finish(Task.isCancelled ? .cancelled : .failed)
                    }
                }
                if let operation = state.operation {
                    Self.pending[queueKey] = (repairID, operation)
                }
                state.timer = Task { @MainActor in
                    do {
                        try await Task.sleep(for: min(deadline, .seconds(1)))
                        state.finish(.deferred)
                        state.operation?.cancel()
                    } catch {}
                }
                if Task.isCancelled {
                    state.finish(.cancelled)
                    state.operation?.cancel()
                }
            }
        } onCancel: {
            Task { @MainActor in
                state.finish(.cancelled)
                state.operation?.cancel()
            }
        }
    }
}

@MainActor
private final class DonationWait {
    private var continuation: CheckedContinuation<SpotlightDonationOutcome, Never>?
    var operation: Task<Void, Never>?
    var timer: Task<Void, Never>?
    private(set) var finished = false
    private var outcome: SpotlightDonationOutcome?

    func install(_ continuation: CheckedContinuation<SpotlightDonationOutcome, Never>) {
        if let outcome {
            continuation.resume(returning: outcome)
        } else {
            self.continuation = continuation
        }
    }

    func finish(_ outcome: SpotlightDonationOutcome) {
        guard !finished else { return }
        finished = true
        self.outcome = outcome
        timer?.cancel()
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
