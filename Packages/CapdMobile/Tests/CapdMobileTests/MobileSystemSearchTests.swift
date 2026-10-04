import Foundation
import Testing

@testable import CapdMobile

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
