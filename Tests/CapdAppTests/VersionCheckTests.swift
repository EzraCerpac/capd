import Foundation
import Testing

@testable import CapdApp
@testable import CapdAppUI

@MainActor
@Suite("Version check")
struct VersionCheckTests {
    @Test("A different fork main revision surfaces an available update")
    func newerRevisionSurfacesUpdate() async {
        let harness = Harness(revision: String(repeating: "b", count: 40))

        await harness.checker.checkIfDue()

        #expect(harness.requestCount == 1)
        #expect(harness.checker.availableVersion == "fork main · bbbbbbb")
    }

    @Test("The running revision stays quiet")
    func runningRevisionStaysQuiet() async {
        let harness = Harness(revision: Harness.currentRevision)

        await harness.checker.checkIfDue()

        #expect(harness.checker.availableVersion == nil)
    }

    @Test("Old cached release tags are ignored")
    func oldCachedReleaseTagIsIgnored() {
        let harness = Harness(revision: String(repeating: "b", count: 40))
        harness.defaults.set("v0.0.9", forKey: "latestKnownVersion")

        #expect(harness.checker.availableVersion == nil)
    }

    @Test("Changing installed revision invalidates the cache and checks immediately")
    func installedRevisionChangeInvalidatesCache() async {
        let harness = Harness(revision: String(repeating: "b", count: 40))
        await harness.checker.checkIfDue()
        harness.setSourceRevision(String(repeating: "b", count: 40))

        #expect(harness.checker.availableVersion == nil)

        await harness.checker.checkIfDue()

        #expect(harness.requestCount == 2)
        #expect(harness.checker.availableVersion == nil)
    }

    @Test("Update command targets the local fork updater")
    func upgradeCommandTargetsForkUpdater() {
        #expect(UpdateChecker.upgradeCommand == "mise -C ~/.config/mise run local:capd-update")
    }

    @Test("Toggled off, no request is made")
    func toggledOffMakesNoRequest() async {
        let harness = Harness(revision: String(repeating: "b", count: 40))
        harness.settings.checksForUpdates = false

        await harness.checker.checkIfDue()

        #expect(harness.requestCount == 0)
        #expect(harness.checker.availableVersion == nil)
    }

    @Test("A second check within the week is skipped")
    func withinWeekSkips() async {
        let harness = Harness(revision: String(repeating: "b", count: 40))

        await harness.checker.checkIfDue()
        harness.advance(by: 3 * 24 * 60 * 60)
        await harness.checker.checkIfDue()

        #expect(harness.requestCount == 1)
    }

    @Test("A check after a week fetches again")
    func afterWeekRefetches() async {
        let harness = Harness(revision: String(repeating: "b", count: 40))

        await harness.checker.checkIfDue()
        harness.advance(by: 8 * 24 * 60 * 60)
        await harness.checker.checkIfDue()

        #expect(harness.requestCount == 2)
    }

    @Test("A failed request retries on the next pass")
    func failureRetriesNextPass() async {
        let harness = Harness(revision: String(repeating: "b", count: 40))
        harness.fails = true

        await harness.checker.checkIfDue()
        #expect(harness.checker.availableVersion == nil)

        harness.fails = false
        await harness.checker.checkIfDue()

        #expect(harness.requestCount == 2)
        #expect(harness.checker.availableVersion == "fork main · bbbbbbb")
    }

    @Test("A found update survives a relaunch")
    func updateSurvivesRelaunch() async {
        let harness = Harness(revision: String(repeating: "b", count: 40))
        await harness.checker.checkIfDue()

        let relaunched = UpdateChecker(
            settings: AppSettings(defaults: harness.defaults),
            client: ReleaseClient { throw URLError(.notConnectedToInternet) },
            sourceRevision: Harness.currentRevision)

        #expect(relaunched.availableVersion == "fork main · bbbbbbb")
    }

    @Test("Settings persist across relaunches")
    func settingsPersist() {
        let harness = Harness(revision: String(repeating: "b", count: 40))
        harness.settings.fetchesPageBodies = false
        harness.settings.checksForUpdates = false
        harness.settings.contextualRemindersEnabled = true

        let relaunched = AppSettings(defaults: harness.defaults)

        #expect(!relaunched.fetchesPageBodies)
        #expect(!relaunched.checksForUpdates)
        #expect(relaunched.contextualRemindersEnabled)
    }

    @Test("Contextual reminders default off")
    func contextualRemindersDefaultOff() {
        let harness = Harness(revision: String(repeating: "b", count: 40))

        #expect(!harness.settings.contextualRemindersEnabled)
    }

    @Test("Changing contextual reminders updates the live monitor")
    func contextualReminderCallback() {
        let harness = Harness(revision: String(repeating: "b", count: 40))
        var changes: [Bool] = []
        harness.settings.contextualRemindersChanged = { changes.append($0) }

        harness.settings.contextualRemindersEnabled = true
        harness.settings.contextualRemindersEnabled = false

        #expect(changes == [true, false])
    }

    @Test("Revision validation rejects release tags")
    func revisionValidation() {
        #expect(SourceRevision.isValid(String(repeating: "a", count: 40)))
        #expect(!SourceRevision.isValid("v0.0.9"))
    }
}

@MainActor
private final class Harness {
    static let currentRevision = String(repeating: "a", count: 40)

    let defaults: UserDefaults
    let settings: AppSettings
    private(set) var checker: UpdateChecker!
    private(set) var requestCount = 0
    var fails = false
    private var sourceRevision: String
    private let targetRevision: String

    private let suiteName = "dev.jxd.capd.tests.\(UUID().uuidString)"
    private var now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init(revision: String) {
        targetRevision = revision
        sourceRevision = Self.currentRevision
        defaults = UserDefaults(suiteName: suiteName)!
        settings = AppSettings(defaults: defaults)
        makeChecker()
    }

    func setSourceRevision(_ revision: String) {
        sourceRevision = revision
        makeChecker()
    }

    private func makeChecker() {
        checker = UpdateChecker(
            settings: settings,
            client: ReleaseClient { @MainActor [unowned self] in
                requestCount += 1
                if fails {
                    throw URLError(.notConnectedToInternet)
                }
                return targetRevision
            },
            sourceRevision: sourceRevision,
            now: { [unowned self] in now })
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}
