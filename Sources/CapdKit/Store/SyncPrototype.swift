import CapdSync
import Foundation
import GRDB

/// An opt-in fixture adapter, never invoked by Store or the capture/enrichment services.
enum SyncPrototype {
    static func backfillIdentities(in writer: any DatabaseWriter) throws -> [Int64: UUID] {
        try writer.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS sync_capture_ids (
                        local_id INTEGER PRIMARY KEY, global_id TEXT NOT NULL UNIQUE)
                    """)
            for capture in try Capture.fetchAll(db) {
                try db.execute(
                    sql: """
                        INSERT INTO sync_capture_ids (local_id, global_id) VALUES (?, ?)
                        ON CONFLICT(local_id) DO NOTHING
                        """, arguments: [capture.id, UUID().uuidString])
            }
            return try Dictionary(
                uniqueKeysWithValues: Row.fetchAll(
                    db,
                    sql: "SELECT local_id, global_id FROM sync_capture_ids"
                ).map { row in
                    let localID: Int64 = row["local_id"]
                    let globalID: String = row["global_id"]
                    return (localID, UUID(uuidString: globalID)!)
                })
        }
    }

    static func snapshot(_ capture: Capture, globalID: UUID, blob: BlobReference? = nil)
        -> SharedCapture
    {
        var record = SharedCapture(
            id: globalID,
            source: CaptureSource(
                kind: CaptureSource.Kind(rawValue: capture.kind.rawValue)!,
                contentHash: capture.contentHash, url: capture.url, host: capture.host,
                title: capture.title, selection: capture.selection, blob: blob),
            createdAt: capture.createdAt, note: capture.note)
        record.seenCount = capture.seenCount
        record.metadata = CaptureMetadata(
            updatedAt: capture.updatedAt, lastSeenAt: capture.lastSeenAt,
            reminderAt: capture.reminderAt, sourceAppBundleID: capture.sourceAppBundleID)
        record.rating = capture.rating
        if capture.tagsVersion == Capture.pinnedTagsVersion {
            record.manualTags = capture.tagList
        } else {
            record.generated.tags = capture.tagList
        }
        record.generated.body = capture.body
        record.generated.ocrText = capture.ocrText
        return record
    }

    static func project(_ db: Database, record: SharedCapture) throws {
        let mappedID = try Int64.fetchOne(
            db, sql: "SELECT local_id FROM sync_capture_ids WHERE global_id = ?",
            arguments: [record.id.uuidString])
        let original = try mappedID.flatMap { try Capture.fetchOne(db, key: $0) }
        if record.deleted {
            if let mappedID { try Capture.deleteOne(db, key: mappedID) }
            return
        }
        var capture =
            original
            ?? Capture(
                id: mappedID,
                kind: CaptureKind(rawValue: record.source.kind.rawValue)!,
                createdAt: record.createdAt)
        capture.url = record.source.url
        capture.host = record.source.host
        capture.title = record.source.title
        capture.selection = record.source.selection
        capture.contentHash = record.source.contentHash
        capture.note = record.note
        capture.rating = record.rating
        capture.seenCount = record.seenCount
        capture.body = record.generated.body
        capture.ocrText = record.generated.ocrText
        if let metadata = record.metadata {
            if let updatedAt = metadata.updatedAt { capture.updatedAt = updatedAt }
            if let lastSeenAt = metadata.lastSeenAt { capture.lastSeenAt = lastSeenAt }
            capture.reminderAt = metadata.reminderAt
            capture.sourceAppBundleID = metadata.sourceAppBundleID
        }
        let tags = Array(Set(record.manualTags).union(record.generated.tags)).sorted()
        capture.tags = tags.isEmpty ? nil : tags.joined(separator: " ")
        capture.tagsVersion =
            record.manualTags.isEmpty
            ? (record.generated.tags.isEmpty ? 0 : 1) : Capture.pinnedTagsVersion
        // Digest filenames are relative, verified, and held in the fixture's assets directory.
        capture.assetPath = record.source.blob?.digest
        if original != nil {
            try capture.update(db)
        } else {
            try capture.insert(db)
        }
        try db.execute(
            sql: """
                INSERT INTO sync_capture_ids (local_id, global_id) VALUES (?, ?)
                ON CONFLICT(global_id) DO UPDATE SET local_id = excluded.local_id
                """, arguments: [capture.id, record.id.uuidString])
    }
}
