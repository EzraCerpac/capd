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
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await sleeper.count == 0 && ContinuousClock.now < deadline {
            await Task.yield()
        }
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
    func started() { count += 1 }
}
