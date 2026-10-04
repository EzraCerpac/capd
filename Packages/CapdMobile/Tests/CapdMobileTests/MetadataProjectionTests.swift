import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdMobile

@Test func sharedMetadataSurvivesProjectionAnnotationReopenAndLegacySchemaUpgrade() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-mobile-metadata-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let created = Date(timeIntervalSinceReferenceDate: 123_456_789.12345679)
    let updated = Date(timeIntervalSinceReferenceDate: 123_456_791.98765432)
    let seen = Date(timeIntervalSinceReferenceDate: 123_456_793.00000012)
    let reminder = Date(timeIntervalSinceReferenceDate: 123_456_799.23456789)
    var record = SharedCapture(
        source: CaptureSource(
            kind: .text, title: "Metadata from Mac", selection: "Synthetic original source"),
        createdAt: created,
        metadata: CaptureMetadata(
            updatedAt: updated, lastSeenAt: seen, reminderAt: reminder,
            sourceAppBundleID: "test.original-mac-app",
            unknownFields: [
                "future": .object(["precise": .number(Decimal(string: "9007199254740993")!)])
            ]))
    record.manualTags = ["manual"]
    let server = try SyncServer(
        databaseURL: root.appendingPathComponent("server.sqlite"),
        blobDirectory: root.appendingPathComponent("server-blobs"))
    let sender = try SyncClient(
        databaseURL: root.appendingPathComponent("sender.sqlite"),
        blobDirectory: root.appendingPathComponent("sender-blobs"))
    try sender.enqueue(captureID: record.id, mutation: .create(record))
    try sender.push(to: server)
    do {
        let mobile = try MobileStore(url: url)
        try mobile.pull(from: server)
        let capture = try #require(try mobile.capture(id: record.id))
        #expect(
            capture.createdAt.timeIntervalSinceReferenceDate
                == created.timeIntervalSinceReferenceDate)
        #expect(capture.metadata == record.metadata)
        try mobile.update(capture, note: "Mobile annotation", tags: ["manual", "extra"])
        #expect(try mobile.capture(id: record.id)?.metadata == record.metadata)
    }
    let before: [Data]
    do {
        let database = try DatabaseQueue(path: url.path)
        before = try database.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
        try database.write { db in
            try db.execute(sql: "ALTER TABLE mobile_captures DROP COLUMN metadata")
            try db.execute(sql: "ALTER TABLE mobile_captures DROP COLUMN createdAtReferenceSeconds")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = 'mobile-original-metadata-v3'")
        }
    }
    let reopened = try MobileStore(url: url)
    let restored = try #require(try reopened.capture(id: record.id))
    #expect(
        restored.createdAt.timeIntervalSinceReferenceDate == created.timeIntervalSinceReferenceDate)
    #expect(restored.metadata == record.metadata)
    #expect(restored.note == "Mobile annotation")
    #expect(restored.manualTags == ["extra", "manual"])
    let database = try DatabaseQueue(path: url.path)
    #expect(
        try database.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        } == before)
    try reopened.push(to: server)
    #expect(try server.baseline().captures[0].metadata == record.metadata)
}

@Test func legacyMobileCapturesKeepMissingMetadataAbsentAndDoNotInventTimestamps() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-mobile-legacy-metadata-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(url: root.appendingPathComponent("mobile.sqlite"))
    let capture = MobileCapture(
        kind: .text, title: "Legacy", selection: "Synthetic legacy source",
        createdAt: Date(timeIntervalSinceReferenceDate: 123_456_789.12345679))
    try store.save(capture)
    let row = try #require(try store.capture(id: capture.id))
    #expect(row.metadata == nil)
    #expect(row.createdAt == capture.createdAt)
    #expect(row.createdAtReferenceSeconds == capture.createdAt.timeIntervalSinceReferenceDate)
}
