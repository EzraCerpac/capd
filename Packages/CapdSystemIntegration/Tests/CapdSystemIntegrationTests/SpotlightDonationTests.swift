import Foundation
import Testing

@testable import CapdSystemIntegration

@MainActor
private final class DonationIndex: SpotlightBackend {
    var items: [String: SearchCapture] = [:]
    var domains: [String] = []
    var removed: [String] = []
    var domainDeletes = 0
    var hold = false
    var failWrite = false
    var failDelete = false
    var pending: CheckedContinuation<Void, Never>?

    func replace(_ captures: [SearchCapture], domain: String) async throws {
        domains.append(domain)
        if hold { await withCheckedContinuation { pending = $0 } }
        for capture in captures { items[capture.id] = capture }
        if failWrite { throw SystemIntegrationError.unavailable }
    }

    func delete(identifiers: [String]) async throws {
        if failDelete { throw SystemIntegrationError.unavailable }
        removed += identifiers
        for id in identifiers { items.removeValue(forKey: id) }
    }

    func delete(domain: String) async throws { domainDeletes += 1 }
}

@MainActor
private final class DonationJournal {
    var tokens: [UUID: CaptureReference] = [:]
    var owners: [String: UUID] = [:]
    var failFinish = false
    func begin(_ token: UUID, _ reference: CaptureReference) {
        tokens[token] = reference
        owners[reference.id] = token
    }
    func finish(_ token: UUID) throws {
        if failFinish { throw SystemIntegrationError.unavailable }
        if let reference = tokens[token], owners[reference.id] == token {
            owners.removeValue(forKey: reference.id)
        }
        tokens.removeValue(forKey: token)
    }
    func owns(_ token: UUID, _ reference: CaptureReference) -> Bool {
        owners[reference.id] == token
    }
    func cleanup(
        _ token: UUID, _ reference: CaptureReference,
        _ remove: @MainActor () async throws -> Void
    ) async throws -> Bool {
        guard owns(token, reference) else { return false }
        // Production callers hold the cross-process index write lease through this await.
        try await remove()
        return true
    }
}

@MainActor
struct SpotlightDonationTests {
    private func fixture(libraryID: UUID = UUID(), text: String = "") -> SearchCapture {
        SearchCapture(
            reference: CaptureReference(libraryID: libraryID, captureID: UUID()),
            title: "Synthetic donation", text: text, keywords: ["synthetic"])
    }

    @Test func singleRecordUpsertPreservesOtherItemsAndNeverResetsDomain() async {
        let index = DonationIndex()
        let journal = DonationJournal()
        let capture = fixture()
        let other = fixture()
        index.items[other.id] = other
        let donor = SpotlightDonation(backend: index, namespace: "synthetic.test")
        for _ in 0..<2 {
            let outcome = await donor.donate(
                capture, isAuthorized: { true }, beginRepair: journal.begin,
                finishRepair: journal.finish, ownsRepair: journal.owns,
                cleanupIfOwned: journal.cleanup)
            #expect(outcome == .indexed)
        }
        #expect(index.items.count == 2)
        #expect(index.items[capture.id] == capture)
        #expect(
            index.domains
                == Array(
                    repeating:
                        "synthetic.test.\(capture.reference.libraryID.uuidString.lowercased())",
                    count: 2))
        #expect(index.domainDeletes == 0)
        #expect(journal.tokens.isEmpty)
    }

    @Test func disabledOrSourceTextNeverStartsWrite() async {
        let index = DonationIndex()
        let journal = DonationJournal()
        let donor = SpotlightDonation(backend: index)
        let disabled = await donor.donate(
            fixture(), isAuthorized: { false }, beginRepair: journal.begin,
            finishRepair: journal.finish, ownsRepair: journal.owns, cleanupIfOwned: journal.cleanup)
        let source = await donor.donate(
            fixture(text: "Private source is excluded"), isAuthorized: { true },
            beginRepair: journal.begin, finishRepair: journal.finish, ownsRepair: journal.owns,
            cleanupIfOwned: journal.cleanup)
        #expect(disabled == .deferred)
        #expect(source == .deferred)
        #expect(index.domains.isEmpty)
        #expect(journal.tokens.isEmpty)
    }

    @Test func deadlineReturnsBeforeOSWriteAndLateCompletionRemovesOnlyOwnItem() async {
        let index = DonationIndex()
        index.hold = true
        let journal = DonationJournal()
        let capture = fixture()
        let other = fixture()
        index.items[other.id] = other
        let donor = SpotlightDonation(backend: index)
        let outcome = await donor.donate(
            capture, deadline: .milliseconds(10), isAuthorized: { true },
            beginRepair: journal.begin, finishRepair: journal.finish, ownsRepair: journal.owns,
            cleanupIfOwned: journal.cleanup)
        #expect(outcome == .deferred)
        #expect(index.pending != nil)
        #expect(journal.tokens.count == 1)
        index.pending?.resume()
        index.pending = nil
        await settle { journal.tokens.isEmpty }
        #expect(index.items[capture.id] == nil)
        #expect(index.items[other.id] == other)
        #expect(index.removed == [capture.id])
        #expect(index.domainDeletes == 0)
        #expect(journal.tokens.isEmpty)
    }

    @Test func cancellationReleasesCallerAndCleansLateWrite() async {
        let index = DonationIndex()
        index.hold = true
        let journal = DonationJournal()
        let capture = fixture()
        let donor = SpotlightDonation(backend: index)
        let task = Task { @MainActor in
            await donor.donate(
                capture, isAuthorized: { true }, beginRepair: journal.begin,
                finishRepair: journal.finish, ownsRepair: journal.owns,
                cleanupIfOwned: journal.cleanup)
        }
        await settle { index.pending != nil }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(journal.tokens.count == 1)
        index.pending?.resume()
        index.pending = nil
        await settle { journal.tokens.isEmpty }
        #expect(index.items.isEmpty)
        #expect(index.removed == [capture.id])
    }

    @Test func optOutOrLibrarySwitchDuringWriteRemovesOldScopedIdentifier() async {
        for changedLibrary in [false, true] {
            let index = DonationIndex()
            index.hold = true
            let journal = DonationJournal()
            let capture = fixture()
            let other = fixture()
            index.items[other.id] = other
            var enabled = true
            var activeLibrary = capture.reference.libraryID
            let donor = SpotlightDonation(backend: index)
            let task = Task { @MainActor in
                await donor.donate(
                    capture,
                    isAuthorized: { enabled && activeLibrary == capture.reference.libraryID },
                    beginRepair: journal.begin, finishRepair: journal.finish,
                    ownsRepair: journal.owns, cleanupIfOwned: journal.cleanup)
            }
            await settle { index.pending != nil }
            if changedLibrary { activeLibrary = UUID() } else { enabled = false }
            index.pending?.resume()
            index.pending = nil
            #expect(await task.value == .deferred)
            #expect(index.items[capture.id] == nil)
            #expect(index.items[other.id] == other)
            #expect(journal.tokens.isEmpty)
        }
    }

    @Test func failedCleanupRetainsDurableRepairToken() async {
        let index = DonationIndex()
        index.failWrite = true
        index.failDelete = true
        let journal = DonationJournal()
        let capture = fixture()
        let outcome = await SpotlightDonation(backend: index).donate(
            capture, isAuthorized: { true }, beginRepair: journal.begin,
            finishRepair: journal.finish, ownsRepair: journal.owns, cleanupIfOwned: journal.cleanup)
        #expect(outcome == .failed)
        #expect(Array(journal.tokens.values) == [capture.reference])
        #expect(index.domainDeletes == 0)
    }

    @Test func journalFailurePreventsOSWrite() async {
        let index = DonationIndex()
        let outcome = await SpotlightDonation(backend: index).donate(
            fixture(), isAuthorized: { true },
            beginRepair: { _, _ in throw SystemIntegrationError.unavailable },
            finishRepair: { _ in }, ownsRepair: { _, _ in true },
            cleanupIfOwned: { _, _, remove in
                try await remove()
                return true
            })
        #expect(outcome == .failed)
        #expect(index.domains.isEmpty)
    }

    @Test func overlappingDonationsSerializeLateCleanupBeforeNewUpsert() async {
        let index = DonationIndex()
        index.hold = true
        let journal = DonationJournal()
        let old = fixture()
        var newer = old
        newer.title = "Synthetic newer title"
        newer.revision = 1
        let donor = SpotlightDonation(backend: index)
        let oldOutcome = await donor.donate(
            old, deadline: .milliseconds(10), isAuthorized: { true },
            beginRepair: journal.begin, finishRepair: journal.finish, ownsRepair: journal.owns,
            cleanupIfOwned: journal.cleanup)
        #expect(oldOutcome == .deferred)
        let nextDonor = SpotlightDonation(backend: index)
        let next = Task { @MainActor in
            await nextDonor.donate(
                newer, isAuthorized: { true }, beginRepair: journal.begin,
                finishRepair: journal.finish, ownsRepair: journal.owns,
                cleanupIfOwned: journal.cleanup)
        }
        await Task.yield()
        #expect(index.domains.count == 1)
        index.hold = false
        index.pending?.resume()
        index.pending = nil
        #expect(await next.value == .indexed)
        #expect(index.items[old.id] == newer)
        #expect(index.removed == [old.id])
        #expect(journal.tokens.isEmpty)
    }

    @Test func newerExternalWriterPreventsStaleCleanupAndRetainsRepairToken() async {
        let index = DonationIndex()
        index.hold = true
        let journal = DonationJournal()
        let capture = fixture()
        let donor = SpotlightDonation(backend: index)
        let outcome = await donor.donate(
            capture, deadline: .milliseconds(10), isAuthorized: { true },
            beginRepair: journal.begin, finishRepair: journal.finish,
            ownsRepair: journal.owns, cleanupIfOwned: journal.cleanup)
        #expect(outcome == .deferred)
        journal.owners[capture.id] = UUID()
        index.pending?.resume()
        index.pending = nil
        await settle { index.items[capture.id] != nil }
        #expect(index.removed.isEmpty)
        #expect(journal.tokens.count == 1)
        #expect(index.domainDeletes == 0)
    }

    @Test func journalFinalizationFailureRetainsTokenAndReportsFailure() async {
        let index = DonationIndex()
        let journal = DonationJournal()
        journal.failFinish = true
        let capture = fixture()
        let outcome = await SpotlightDonation(backend: index).donate(
            capture, isAuthorized: { true }, beginRepair: journal.begin,
            finishRepair: journal.finish, ownsRepair: journal.owns, cleanupIfOwned: journal.cleanup)
        #expect(outcome == .failed)
        #expect(Array(journal.tokens.values) == [capture.reference])
        #expect(index.items[capture.id] == nil)
    }

    @Test func newerOwnerDuringLiveWriteDefersInsteadOfAcknowledgingOldToken() async {
        let index = DonationIndex()
        index.hold = true
        let journal = DonationJournal()
        let capture = fixture()
        let donor = SpotlightDonation(backend: index)
        let task = Task { @MainActor in
            await donor.donate(
                capture, isAuthorized: { true }, beginRepair: journal.begin,
                finishRepair: journal.finish, ownsRepair: journal.owns,
                cleanupIfOwned: journal.cleanup)
        }
        await settle { index.pending != nil }
        journal.owners[capture.id] = UUID()
        index.pending?.resume()
        index.pending = nil
        #expect(await task.value == .deferred)
        #expect(index.removed.isEmpty)
        #expect(journal.tokens.count == 1)
    }

    @Test func queuedDonationDeadlineNeverStartsAnotherWrite() async {
        let index = DonationIndex()
        index.hold = true
        let journal = DonationJournal()
        let capture = fixture()
        let donor = SpotlightDonation(backend: index)
        #expect(
            await donor.donate(
                capture, deadline: .milliseconds(10), isAuthorized: { true },
                beginRepair: journal.begin, finishRepair: journal.finish, ownsRepair: journal.owns,
                cleanupIfOwned: journal.cleanup) == .deferred)
        #expect(
            await donor.donate(
                capture, deadline: .milliseconds(10), isAuthorized: { true },
                beginRepair: journal.begin, finishRepair: journal.finish, ownsRepair: journal.owns,
                cleanupIfOwned: journal.cleanup) == .deferred)
        #expect(index.domains.count == 1)
        index.pending?.resume()
        index.pending = nil
        await settle { journal.tokens.isEmpty }
        #expect(index.domains.count == 1)
        #expect(index.items.isEmpty)
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        #expect(predicate())
    }
}
