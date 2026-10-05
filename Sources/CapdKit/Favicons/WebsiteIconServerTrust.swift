import Foundation
import Security

enum WebsiteIconServerTrust {
    // Security cannot cancel an evaluation; its slot lasts until the actual callback.
    private static let capacity = Capacity()

    private final class Capacity: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        func acquire() -> Bool {
            lock.withLock {
                guard active < 2 else { return false }
                active += 1
                return true
            }
        }
        func release() { lock.withLock { active -= 1 } }
    }
    static func configure(_ trust: SecTrust, host: String) throws {
        let policies = [
            SecPolicyCreateSSL(true, host as CFString),
            SecPolicyCreateRevocation(
                CFOptionFlags(
                    kSecRevocationUseAnyAvailableMethod | kSecRevocationNetworkAccessDisabled)),
        ]
        guard SecTrustSetPolicies(trust, policies as CFArray) == errSecSuccess,
            SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess
        else { throw WebsiteIconTransportError.trust }
    }

    static func evaluate(_ trust: SecTrust, host: String, deadline: ContinuousClock.Instant)
        async throws
    {
        try configure(trust, host: host)
        try Task.checkCancellation()
        let evaluation = Evaluation(trust: trust, deadline: deadline)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { evaluation.start($0) }
        } onCancel: {
            evaluation.cancel()
        }
    }

    private final class Evaluation: @unchecked Sendable {
        let trust: SecTrust
        let deadline: ContinuousClock.Instant
        private let queue = DispatchQueue(label: "capd.website-icon.trust")
        private var continuation: CheckedContinuation<Void, any Error>?
        private var cancelled = false
        private var timeout: DispatchWorkItem?
        private var evaluating = false

        init(trust: SecTrust, deadline: ContinuousClock.Instant) {
            self.trust = trust
            self.deadline = deadline
        }
        func start(_ continuation: CheckedContinuation<Void, any Error>) {
            queue.async {
                self.continuation = continuation
                guard !self.cancelled else {
                    self.finish(.failure(CancellationError()))
                    return
                }
                let remaining = ContinuousClock.now.duration(to: self.deadline).components
                let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                guard seconds > 0 else {
                    self.finish(.failure(WebsiteIconTransportError.deadline))
                    return
                }
                guard capacity.acquire() else {
                    self.finish(.failure(WebsiteIconTransportError.busy))
                    return
                }
                self.evaluating = true
                let timeout = DispatchWorkItem {
                    self.finish(.failure(WebsiteIconTransportError.deadline))
                }
                self.timeout = timeout
                self.queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
                let status = SecTrustEvaluateAsyncWithError(self.trust, self.queue) { _, valid, _ in
                    self.releaseCapacity()
                    guard ContinuousClock.now < self.deadline else {
                        self.finish(.failure(WebsiteIconTransportError.deadline))
                        return
                    }
                    self.finish(valid ? .success(()) : .failure(WebsiteIconTransportError.trust))
                }
                if status != errSecSuccess {
                    self.releaseCapacity()
                    self.finish(.failure(WebsiteIconTransportError.trust))
                }
            }
        }
        private func releaseCapacity() {
            guard evaluating else { return }
            evaluating = false
            capacity.release()
        }
        func cancel() {
            queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
        private func finish(_ result: Result<Void, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel()
            timeout = nil
            continuation.resume(with: result)
        }
    }
}
