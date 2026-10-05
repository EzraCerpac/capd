import Foundation
import Testing

@testable import CapdApp
@testable import CapdKit

@MainActor
@Suite("Reminder scheduler")
struct ReminderSchedulerTests {
    @Test("A pulled reminder wakes a scheduler that found no pending reminders")
    func refreshRestartsIdleScheduler() async {
        let now = Date()
        var due: Capture?
        var presented: [Int64] = []
        let scheduler = ReminderScheduler(
            environment: .init(
                claimNextDue: { _ in
                    defer { due = nil }
                    return due
                },
                nextDate: { due?.reminderAt },
                present: { presented.append($0.id!) },
                now: { now }, sleep: { _ in }))
        scheduler.start()
        await scheduler.settle()
        due = Capture(id: 1, kind: .text, reminderAt: now, createdAt: now)
        scheduler.refresh()
        await scheduler.settle()
        #expect(presented == [1])
    }

    @Test("A pulled earlier reminder interrupts a later sleep")
    func refreshReschedulesEarlierReminder() async throws {
        let now = Date()
        var nextDate: Date? = now.addingTimeInterval(3600)
        var due: Capture?
        var presented: [Int64] = []
        let sleeper = ReminderSleepProbe()
        let scheduler = ReminderScheduler(
            environment: .init(
                claimNextDue: { _ in
                    guard let capture = due else { return nil }
                    due = nil
                    nextDate = nil
                    return capture
                },
                nextDate: { nextDate },
                present: { presented.append($0.id!) },
                now: { now },
                sleep: { duration in
                    if duration == .seconds(7) { return }
                    await sleeper.started()
                    try await Task.sleep(for: .seconds(30))
                }))
        scheduler.start()
        let started = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await sleeper.waitForStart() }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
        try #require(started)
        try #require(await sleeper.count == 1)
        scheduler.refresh()
        await Task.yield()
        #expect(await sleeper.count == 1)
        due = Capture(id: 2, kind: .text, reminderAt: now, createdAt: now)
        nextDate = now
        scheduler.refresh()
        await scheduler.settle()
        #expect(presented == [2])
    }

    @Test("Sync refresh preserves the presentation throttle before showing another due reminder")
    func refreshPreservesPresentationThrottle() async throws {
        let now = Date()
        var due: [Capture] = []
        var nextDate: Date? = now
        var presented: [Int64] = []
        let throttle = ReminderSleepProbe()
        let sleeper = ReminderThrottleGate()
        let scheduler = ReminderScheduler(
            environment: .init(
                claimNextDue: { _ in
                    guard !due.isEmpty else { return nil }
                    let capture = due.removeFirst()
                    nextDate = due.first?.reminderAt
                    return capture
                },
                nextDate: { nextDate },
                present: { presented.append($0.id!) },
                now: { now },
                sleep: { duration in
                    if duration == .seconds(7) {
                        await throttle.started()
                        try await sleeper.wait()
                    } else {
                        await sleeper.scheduled()
                    }
                }))
        scheduler.start()
        await sleeper.waitForSchedule()
        due = [
            Capture(id: 1, kind: .text, reminderAt: now.addingTimeInterval(-2), createdAt: now),
            Capture(id: 2, kind: .text, reminderAt: now.addingTimeInterval(-1), createdAt: now),
        ]
        scheduler.reload()
        try #require(await throttle.waitForStart())
        scheduler.refresh()
        for _ in 0..<20 { await Task.yield() }
        #expect(await sleeper.cancellations == 0)
        #expect(presented == [1])
        due[0].reminderAt = now.addingTimeInterval(-3)
        nextDate = due[0].reminderAt
        scheduler.refresh()
        for _ in 0..<20 { await Task.yield() }
        #expect(await sleeper.cancellations == 0)
        #expect(presented == [1])
        await sleeper.release()
        await scheduler.settle()
        #expect(presented == [1, 2])
    }

    @Test("An overdue reminder is presented and claimed once")
    func presentsOverdueReminder() async {
        let capture = Capture(
            id: 1,
            kind: .link,
            url: "https://example.com",
            title: "Example",
            createdAt: Date())
        var due: Capture? = capture
        var presented: [Int64] = []
        let scheduler = ReminderScheduler(
            environment: ReminderScheduler.Environment(
                claimNextDue: { _ in
                    defer { due = nil }
                    return due
                },
                nextDate: { nil },
                present: { presented.append($0.id!) },
                sleep: { _ in }))

        scheduler.start()
        await scheduler.settle()

        #expect(presented == [1])
        #expect(due == nil)
    }
}

private actor ReminderSleepProbe {
    var count = 0
    private let starts: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (starts, continuation) = AsyncStream.makeStream()
    }

    func started() {
        count += 1
        continuation.yield(())
    }

    func waitForStart() async -> Bool {
        var iterator = starts.makeAsyncIterator()
        if case .some = await iterator.next() { return true }
        return false
    }
}

private actor ReminderThrottleGate {
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var released = false
    private let schedules: AsyncStream<Void>
    private let scheduleContinuation: AsyncStream<Void>.Continuation
    var cancellations = 0

    init() {
        (schedules, scheduleContinuation) = AsyncStream.makeStream()
    }

    func scheduled() { scheduleContinuation.yield(()) }

    func waitForSchedule() async {
        var iterator = schedules.makeAsyncIterator()
        _ = await iterator.next()
    }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    cancellations += 1
                    continuation.resume(throwing: CancellationError())
                } else if released {
                    continuation.resume()
                } else {
                    continuations[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        cancellations += 1
        continuation.resume(throwing: CancellationError())
    }

    func release() {
        released = true
        for continuation in continuations.values { continuation.resume() }
        continuations.removeAll()
    }
}
