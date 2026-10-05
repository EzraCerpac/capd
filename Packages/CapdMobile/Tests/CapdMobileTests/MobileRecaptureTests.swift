import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdMobile

@Suite("Mobile recapture admission")
struct MobileRecaptureTests {
    @Test(arguments: ["pending", "accepted", "remote"], ["canonical", "alias", "fresh"])
    func deletedCaptureSaveIsRefusedWithoutChangingDurableState(
        deletion: String, identity: String
    ) throws {
        let fixture = RecaptureFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        let server = try fixture.server()
        let other = try fixture.other()
        let canonical = SharedCapture(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000100")!,
            source: CaptureSource(
                kind: .text,
                contentHash: CaptureFingerprint.contentHash(for: Data("Retained source".utf8)),
                title: "Retained title", selection: "Retained source"), note: "Retained note")
        try other.enqueue(captureID: canonical.id, mutation: .create(canonical))
        try other.push(to: server)
        try store.pull(from: server)
        let aliasID = UUID(uuidString: "00000000-0000-0000-0000-000000000200")!
        let alias = MobileCapture(
            id: aliasID, kind: .text, title: "Alias title", selection: "Retained source")
        try store.save(alias)
        try store.push(to: server)
        #expect(try store.capture(id: aliasID)?.id == canonical.id)
        if deletion == "remote" {
            try other.pull(from: server)
            try other.enqueue(captureID: canonical.id, mutation: .delete)
            try other.push(to: server)
            try store.pull(from: server)
        } else {
            try store.delete(id: aliasID)
            if deletion == "accepted" { try store.push(to: server) }
        }
        #expect(try store.capture(id: aliasID) == nil)
        let retryID =
            identity == "canonical" ? canonical.id : identity == "alias" ? aliasID : UUID()
        let retry = MobileCapture(
            id: retryID, kind: .text, title: "Retry title", selection: "Retained source",
            note: "Retry note")
        let before = try fixture.snapshot()
        #expect(throws: MobileCaptureSaveError.deletedCapture) { try store.save(retry) }
        #expect(try fixture.snapshot() == before)
        #expect(try store.search().isEmpty)

        if deletion == "pending" { try store.push(to: server) }
        let tombstone = try #require(server.baseline().captures.first)
        #expect(tombstone.deleted)
        let stale = try server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: canonical.id,
                baseRevision: tombstone.revision - 1, mutation: .restore))
        #expect(stale.outcome == .staleRestore)
        try other.pull(from: server)
        try other.enqueue(
            captureID: canonical.id, mutation: .restore, baseRevision: tombstone.revision)
        #expect(try other.push(to: server).first?.outcome == .accepted)
        try store.pull(from: server)
        #expect(try store.capture(id: aliasID)?.id == canonical.id)
        #expect(try store.capture(id: aliasID)?.note == "Retained note")
        let restoredRetry = MobileCapture(
            kind: .text, title: "Retry title", selection: "Retained source")
        try store.save(restoredRetry)
        #expect(try store.push(to: server).first?.outcome == .accepted)
        #expect(try store.capture(id: restoredRetry.id)?.id == canonical.id)
        #expect(try store.pending().isEmpty)
    }

    @Test func liveSameKindRecaptureKeepsFingerprintAndCanonicalIdentity() throws {
        let fixture = RecaptureFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        let server = try fixture.server()
        let first = try CaptureInput.make(text: "https://example.invalid/a", isLink: true)
        try store.save(first)
        try store.push(to: server)
        let again = try CaptureInput.make(
            text: "https://EXAMPLE.invalid:443/a#fragment", isLink: true)
        try store.save(again)
        let queued = try #require(store.pending().first)
        guard case .create(let record) = queued.mutation else {
            Issue.record("Expected a duplicate create")
            return
        }
        #expect(
            record.source.contentHash
                == CaptureFingerprint.contentHash(for: URL(string: first.url!)!))
        #expect(try store.capture(id: again.id)?.id == first.id)
        #expect(try store.push(to: server).first?.outcome == .accepted)
        #expect(try server.baseline().captures.count == 1)
        #expect(try store.capture(id: first.id)?.seenCount == 2)
    }

    @Test func otherKindTombstoneDoesNotBlockSameHashCapture() throws {
        let fixture = RecaptureFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        let server = try fixture.server()
        let url = "https://example.invalid/collision"
        let text = try CaptureInput.make(text: url, isLink: false)
        try store.save(text)
        try store.push(to: server)
        try store.delete(id: text.id)
        try store.push(to: server)
        let link = try CaptureInput.make(text: url, isLink: true)
        try store.save(link)
        #expect(try store.push(to: server).first?.outcome == .accepted)
        #expect(try store.capture(id: link.id)?.id == link.id)
        let records = try server.baseline().captures
        #expect(records.count == 2)
        #expect(records.first { $0.source.kind == .text }?.deleted == true)
        #expect(records.first { $0.source.kind == .link }?.deleted == false)
        #expect(Set(records.compactMap { $0.source.contentHash }).count == 1)
    }
}

private struct RecaptureFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-mobile-recapture-\(UUID())")
    var url: URL { directory.appendingPathComponent("mobile.sqlite") }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    func server() throws -> SyncServer {
        try SyncServer(
            databaseURL: directory.appendingPathComponent("server.sqlite"),
            blobDirectory: directory.appendingPathComponent("server-assets"))
    }
    func other() throws -> SyncClient {
        try SyncClient(
            databaseURL: directory.appendingPathComponent("other.sqlite"),
            blobDirectory: directory.appendingPathComponent("other-assets"))
    }
    func snapshot() throws -> [String: [Row]] {
        let database = try DatabaseQueue(path: url.path)
        return try database.read { db in
            try Dictionary(
                uniqueKeysWithValues: [
                    "sync_meta", "sync_outbox", "sync_visible", "sync_records", "sync_aliases",
                    "sync_rejections", "mobile_captures",
                ].map { name in
                    (name, try Row.fetchAll(db, sql: "SELECT * FROM \(name) ORDER BY rowid"))
                })
        }
    }
}
