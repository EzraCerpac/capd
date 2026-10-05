import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdMobile

private struct DiscoveryFixture: Sendable {
    let root: URL
    let session: MobileLibrarySession
    let writer: DatabaseQueue

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        session = try MobileLibrarySession.open(root: root, role: .shareExtension)
        writer = try DatabaseQueue(path: session.configuration.databaseURL(in: root).path)
    }
}

@Suite struct MobileDiscoverySnapshotTests {
    @Test func skipsLargePrivatePayloadsAndExcludedJSONDecoders() async throws {
        let f = try DiscoveryFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try f.session.save(CaptureInput.make(text: "Synthetic source", isLink: false))
        try await f.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE mobile_captures SET body=?, ocrText=?, note=?,
                        noteConflicts='invalid excluded JSON', metadata='invalid excluded JSON',
                        generatedTags='invalid excluded JSON'
                    """,
                arguments: [
                    String(repeating: "Synthetic body. ", count: 65_536),
                    String(repeating: "Synthetic OCR. ", count: 65_536),
                    String(repeating: "Synthetic note. ", count: 65_536),
                ])
        }
        #expect(throws: (any Error).self) { try f.session.store.systemSearchSnapshot() }
        let snapshot = try f.session.store.systemSearchDiscoverySnapshot()
        #expect(!snapshot.exceedsLimit)
        #expect(snapshot.captures == [MobileSystemSearchCapture(saved.capture)])
        #expect(snapshot.revision != nil)
    }

    @Test func rejectsTheThousandAndFirstBeforeDecodingAndCountsOnlyLiveRows() async throws {
        let f = try DiscoveryFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try f.session.save(
            CaptureInput.make(text: "Original synthetic source", isLink: false))
        try await f.writer.write { db in
            for index in 0..<999 {
                var item = MobileCapture(kind: .text, title: "Source \(index)")
                try item.insert(db)
            }
        }
        let accepted = try f.session.store.systemSearchDiscoverySnapshot()
        #expect(!accepted.exceedsLimit && accepted.captures.count == 1000)
        let extra = UUID()
        try await f.writer.write { db in
            var item = MobileCapture(id: extra, kind: .text, title: "Extra")
            try item.insert(db)
            try db.execute(
                sql: "UPDATE mobile_captures SET manualTags='[1]' WHERE id=?",
                arguments: [extra.uuidString])
        }
        let rejected = try f.session.store.systemSearchDiscoverySnapshot()
        #expect(rejected.exceedsLimit && rejected.captures.isEmpty)
        #expect(rejected.revision == accepted.revision)
        try await f.writer.write { db in
            try db.execute(
                sql: "DELETE FROM mobile_captures WHERE id=?", arguments: [extra.uuidString])
            try db.execute(
                sql: "UPDATE mobile_captures SET manualTags='[1]' WHERE id=?",
                arguments: [original.capture.id.uuidString])
        }
        let retainedCount = try await f.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mobile_captures")
        }
        #expect(retainedCount == 1000)
        #expect(throws: DecodingError.self) {
            try f.session.store.systemSearchDiscoverySnapshot()
        }
        try await f.writer.write { db in
            try db.execute(
                sql: "UPDATE mobile_captures SET manualTags='[]' WHERE id=?",
                arguments: [original.capture.id.uuidString])
        }
        try f.session.store.delete(id: original.capture.id)
        let deleted = try f.session.store.systemSearchDiscoverySnapshot()
        #expect(!deleted.exceedsLimit && deleted.captures.count == 999)
        #expect(!deleted.captures.contains { $0.id == original.capture.id })
    }

    @Test func boundsRetainedFieldsBeforeDecodingAndRefusesAmbiguousPrefixes() async throws {
        let f = try DiscoveryFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.session.save(CaptureInput.make(text: "Synthetic source", isLink: false))
        for (title, selection, tags) in [
            (String(repeating: "T", count: 4097), "Source", "[]"),
            ("Title", "Source", String(repeating: "?", count: 16_385)),
            ("Title", String(repeating: "\u{3000}", count: 2000) + "Source", "[]"),
            ("Title", "e" + String(repeating: "\u{301}", count: 3000), "[]"),
        ] {
            try await f.writer.write { db in
                try db.execute(
                    sql: "UPDATE mobile_captures SET title=?, selection=?, manualTags=?",
                    arguments: [title, selection, tags])
            }
            let snapshot = try f.session.store.systemSearchDiscoverySnapshot()
            #expect(snapshot.exceedsLimit && snapshot.captures.isEmpty)
            #expect(snapshot.revision != nil)
        }
    }

    @Test func rejectsAggregateMetadataBeforeRetainedJSONDecoding() async throws {
        let f = try DiscoveryFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.writer.write { db in
            for index in 0..<600 {
                var item = MobileCapture(kind: .text, title: "Source \(index)")
                try item.insert(db)
            }
            try db.execute(
                sql: "UPDATE mobile_captures SET title=?, manualTags=?",
                arguments: [
                    String(repeating: "T", count: 4096), String(repeating: "?", count: 12_288),
                ])
        }
        let snapshot = try f.session.store.systemSearchDiscoverySnapshot()
        #expect(snapshot.exceedsLimit && snapshot.captures.isEmpty)
    }

    @Test func preservesUnicodeTitlePrivacyAndCanonicalMetadataProjection() async throws {
        let f = try DiscoveryFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = "\u{3000}\n" + String(repeating: "👩🏽‍💻", count: 1000) + "\n"
        let derived = String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        var text = MobileCapture(kind: .text, title: derived, selection: source)
        text.manualTags =
            ["A manual tag", String(repeating: "e\u{301}", count: 100)]
            + (0..<40).map { "Tag \($0)" }
        text.revision = 7
        var explicit = MobileCapture(kind: .text, title: "Explicit title", selection: source)
        explicit.manualTags = text.manualTags
        var link = MobileCapture(kind: .link, title: "Link title", selection: source)
        link.revision = 9
        let image = MobileCapture(kind: .image, title: "Image title", selection: source)
        let items = [text, explicit, link, image]
        try await f.writer.write { db in
            for var item in items { try item.insert(db) }
        }
        let snapshot = try f.session.store.systemSearchDiscoverySnapshot()
        #expect(!snapshot.exceedsLimit)
        let expected = items.map(MobileSystemSearchCapture.init).sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        #expect(snapshot.captures == expected)
        #expect(snapshot.captures.allSatisfy { $0.derivedTitle == derived })
    }

    @Test func oldDiscoveryCompletionCannotAcknowledgeNewSaveAndSessionIsFenced() async throws {
        let f = try DiscoveryFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.session.save(CaptureInput.make(text: "First source", isLink: false))
        let before = try f.session.store.systemSearchDiscoverySnapshot()
        _ = try f.session.save(CaptureInput.make(text: "Second source", isLink: false))
        try f.session.store.acknowledgeSystemSearch(before.revision)
        let after = try f.session.store.systemSearchDiscoverySnapshot()
        #expect(after.revision != nil && after.revision != before.revision)
        #expect(after.captures.count == 2)
        let enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.invalid/v1/sync")!,
            binding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()), deviceID: UUID())
        let configuration = MobileLibraryConfiguration(generation: UUID(), enrollment: enrollment)
        try JSONEncoder().encode(configuration).write(
            to: f.root.appendingPathComponent("active-library.json"))
        #expect(throws: MobileActivationError.sessionReplaced) {
            try f.session.store.systemSearchDiscoverySnapshot()
        }
    }

    @Test func revisionAndRowsShareOneReadSnapshotDuringConcurrentWrites() async throws {
        let f = try DiscoveryFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.session.save(CaptureInput.make(text: "Synthetic source", isLink: false))
        let first = UUID()
        let second = UUID()
        try await f.writer.write { db in
            try db.execute(sql: "UPDATE mobile_captures SET revision=1")
            try db.execute(
                sql: "UPDATE mobile_system_search SET revision=?", arguments: [first.uuidString])
        }
        let writer = Task.detached {
            for index in 0..<300 {
                try await f.writer.write { db in
                    try db.execute(
                        sql: "UPDATE mobile_captures SET revision=?",
                        arguments: [index.isMultiple(of: 2) ? 1 : 2])
                    try db.execute(
                        sql: "UPDATE mobile_system_search SET revision=?",
                        arguments: [index.isMultiple(of: 2) ? first.uuidString : second.uuidString])
                }
            }
        }
        for _ in 0..<300 {
            let snapshot = try f.session.store.systemSearchDiscoverySnapshot()
            #expect(!snapshot.exceedsLimit && snapshot.captures.count == 1)
            #expect(snapshot.revision == first || snapshot.revision == second)
            #expect(snapshot.captures.first?.revision == (snapshot.revision == first ? 1 : 2))
        }
        try await writer.value
    }
}

@Test func closedAppShareHasDurableSearchHandoffAndOldCompletionCannotAcknowledgeNewSave()
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-search-handoff-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let share = try MobileLibrarySession.open(root: root, role: .shareExtension)
    let first = try CaptureInput.make(text: "Synthetic marsh source", isLink: false)
    let saved = try share.save(first)
    #expect(saved.capture.id == first.id)
    let app = try MobileLibrarySession.open(root: root, role: .app)
    let before = try app.store.systemSearchSnapshot()
    #expect(before.revision != nil)
    #expect(before.captures.map(\.id) == [first.id])
    try await app.withSystemSearchLease {
        _ = try share.save(CaptureInput.make(text: "Synthetic river source", isLink: false))
        try app.store.acknowledgeSystemSearch(before.revision)
    }
    let reopened = try MobileLibrarySession.open(root: root, role: .app)
    let after = try reopened.store.systemSearchSnapshot()
    #expect(after.revision != nil && after.revision != before.revision)
    #expect(after.captures.count == 2)
    #expect(try reopened.store.pending().count == 2)
    try reopened.store.acknowledgeSystemSearch(after.revision)
    #expect(try reopened.store.systemSearchSnapshot().revision == nil)
    try reopened.store.delete(id: first.id)
    let deleted = try reopened.store.systemSearchSnapshot()
    #expect(deleted.revision != nil)
    #expect(!deleted.captures.contains { $0.id == first.id })
}

@Test func searchRepairScopesSurviveReopenAndRetireOnlyAfterConfirmedRemoval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-search-repair-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try MobileLibrarySession.open(root: root, role: .app)
    let old = UUID()
    let new = UUID()
    try await session.withSystemSearchLease {
        let journal = MobileSystemSearchJournal(root: root)
        try journal.begin(old)
        try journal.begin(new)
        try journal.begin(old)
        #expect(Set(try MobileSystemSearchJournal(root: root).libraries()) == Set([old, new]))
        try journal.removed(old)
        #expect(try journal.libraries() == [new])
        try journal.removed(new)
        #expect(try journal.libraries().isEmpty)
    }
    let bytes = try Data(contentsOf: root.appendingPathComponent("system-search-repair.json"))
    #expect(String(decoding: bytes, as: UTF8.self).contains("libraries"))
}

@Test func malformedSearchRepairIsRetainedAndRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-search-invalid-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = root.appendingPathComponent("system-search-repair.json")
    let bytes = Data("{\"version\":99,\"libraries\":[]}".utf8)
    try bytes.write(to: path)
    #expect(throws: MobileActivationError.invalidConfiguration) {
        try MobileSystemSearchJournal(root: root).begin(UUID())
    }
    #expect(try Data(contentsOf: path) == bytes)
}

@Test func searchCleanupLeaseDoesNotReadTheSelectedConfigurationOrDatabase() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configuration = root.appendingPathComponent("active-library.json")
    let database = try MobileLibraryConfiguration.legacy.databaseURL(in: root)
    let corrupt = Data("Synthetic corrupt selection".utf8)
    try corrupt.write(to: configuration)
    try FileManager.default.createDirectory(
        at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
    try corrupt.write(to: database)
    let libraryID = UUID()
    try await MobileSystemSearchJournal.withLease(root: root) {
        let journal = MobileSystemSearchJournal(root: root)
        try journal.begin(libraryID)
        #expect(try journal.libraries() == [libraryID])
        try journal.removed(libraryID)
        #expect(try journal.libraries().isEmpty)
    }
    #expect(try Data(contentsOf: configuration) == corrupt)
    #expect(try Data(contentsOf: database) == corrupt)
}

@Test func searchCleanupLeaseHonorsActivationAndSearchExclusion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for lockName in [".library-transition.lock", ".system-search.lock"] {
        let held = try MobileLibraryLease(root: root, exclusive: true, fileName: lockName)
        await #expect(throws: MobileActivationError.transitionBusy) {
            try await MobileSystemSearchJournal.withLease(root: root) {
                try MobileSystemSearchJournal(root: root).begin(UUID())
            }
        }
        #expect(try MobileSystemSearchJournal(root: root).libraries().isEmpty)
        withExtendedLifetime(held) {}
    }
    let remaining = try await MobileSystemSearchJournal.withLease(root: root) {
        try MobileSystemSearchJournal(root: root).libraries()
    }
    #expect(remaining.isEmpty)
}
