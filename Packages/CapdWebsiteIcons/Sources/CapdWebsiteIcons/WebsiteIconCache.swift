import Foundation

public actor WebsiteIconCache {
    public typealias Loader = @Sendable (WebsiteIconIdentity) async throws -> Data?
    private struct Entry {
        let image: WebsiteIconImage
        var used: UInt64
    }
    private struct Job {
        let id: UUID
        let load: Loader
        var waiters: [UUID: CheckedContinuation<WebsiteIconImage?, Never>]
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
    }
    private let load: Loader?
    private var memory: [WebsiteIconIdentity: Entry] = [:]
    private var jobs: [WebsiteIconIdentity: Job] = [:]
    private var queue: [WebsiteIconIdentity] = []
    private var active = 0
    private var tick: UInt64 = 0

    public init(load: Loader? = nil) { self.load = load }

    public func image(for identity: WebsiteIconIdentity, load: Loader? = nil) async
        -> WebsiteIconImage?
    {
        guard !Task.isCancelled, identity.normalizerVersion == 1 else { return nil }
        if let entry = memory[identity] {
            remember(entry.image, for: identity)
            return entry.image
        }
        guard jobs.count < 16 || jobs[identity] != nil, let loader = load ?? self.load else {
            return nil
        }
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                if jobs[identity] != nil {
                    jobs[identity]?.waiters[waiter] = continuation
                } else {
                    let id = UUID()
                    jobs[identity] = Job(id: id, load: loader, waiters: [waiter: continuation])
                    queue.append(identity)
                    jobs[identity]?.deadline = Task {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        discard(identity, id: id)
                    }
                }
                startQueued()
            }
        } onCancel: {
            Task { await self.cancel(waiter, for: identity) }
        }
    }

    public func reset() {
        memory = [:]
        for (identity, job) in jobs { discard(identity, id: job.id) }
    }

    private func remember(_ image: WebsiteIconImage, for identity: WebsiteIconIdentity) {
        tick &+= 1
        memory[identity] = Entry(image: image, used: tick)
        if memory.count > 128, let oldest = memory.min(by: { $0.value.used < $1.value.used })?.key {
            memory[oldest] = nil
        }
    }

    private func cancel(_ waiter: UUID, for identity: WebsiteIconIdentity) {
        guard let continuation = jobs[identity]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        if let job = jobs[identity], job.waiters.isEmpty { discard(identity, id: job.id) }
    }

    private func discard(_ identity: WebsiteIconIdentity, id: UUID) {
        guard let job = jobs[identity], job.id == id else { return }
        jobs[identity] = nil
        queue.removeAll { $0 == identity }
        job.task?.cancel()
        job.deadline?.cancel()
        for waiter in job.waiters.values { waiter.resume(returning: nil) }
    }

    private func startQueued() {
        while active < 2, !queue.isEmpty {
            let identity = queue.removeFirst()
            guard let job = jobs[identity] else { continue }
            active += 1
            let id = job.id
            let load = job.load
            jobs[identity]?.task = Task {
                let data = try? await load(identity)
                let image = data.flatMap { WebsiteIconImage.decode($0, identity: identity) }
                complete(image, for: identity, id: id)
            }
        }
    }

    private func complete(_ image: WebsiteIconImage?, for identity: WebsiteIconIdentity, id: UUID) {
        active -= 1
        defer { startQueued() }
        guard let job = jobs[identity], job.id == id else { return }
        jobs[identity] = nil
        job.deadline?.cancel()
        if let image { remember(image, for: identity) }
        for waiter in job.waiters.values { waiter.resume(returning: image) }
    }
}
