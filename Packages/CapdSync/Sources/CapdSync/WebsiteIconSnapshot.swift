import Foundation
import GRDB

enum WebsiteIconSnapshot {
    static func decisions(
        _ db: Database, incoming: [WebsiteIconRecord]?, captures: [UUID: SharedCapture]
    ) throws -> (records: [WebsiteIconRecord], cursor: Int64)? {
        guard let incoming else { return nil }
        var icons = Dictionary(
            uniqueKeysWithValues: try WebsiteIconDatabase.records(db).map { ($0.id, $0) })
        var cursor =
            try WebsiteIconDatabase.exists(db)
            ? Int64.fetchOne(db, sql: "SELECT cursor FROM sync_website_icon_meta")! : 0
        var liveOrigins: Set<String> = []
        let rows = try Data.fetchCursor(db, sql: "SELECT payload FROM sync_records ORDER BY id")
        var seen: Set<UUID> = []
        while let data = try rows.next() {
            let old = try SyncDatabase.decode(SharedCapture.self, data)
            let capture = captures[old.id] ?? old
            seen.insert(capture.id)
            if !capture.deleted, capture.source.kind == .link, let url = capture.source.url,
                let origin = WebsiteIconOrigin(url: url)
            {
                liveOrigins.insert(origin.id)
            }
        }
        for capture in captures.values
        where !seen.contains(capture.id) && !capture.deleted && capture.source.kind == .link {
            if let url = capture.source.url, let origin = WebsiteIconOrigin(url: url) {
                liveOrigins.insert(origin.id)
            }
        }
        func next() throws -> Int64 {
            guard cursor < Int64.max else { throw SyncError.invalidCursor }
            cursor += 1
            return cursor
        }
        for id in icons.keys.sorted() {
            let icon = icons[id]!
            if !icon.deleted && !liveOrigins.contains(id) {
                icons[id] = WebsiteIconRecord(
                    origin: icon.origin, revision: try next(), deleted: true, content: icon.content)
            }
        }
        for icon in incoming.sorted(by: { $0.id < $1.id }) where icons[icon.id] == nil {
            icons[icon.id] = WebsiteIconRecord(
                origin: icon.origin, revision: try next(),
                deleted: icon.deleted || !liveOrigins.contains(icon.id), content: icon.content)
        }
        let records = icons.values.sorted { $0.id < $1.id }
        guard records.count <= 4096,
            try SyncDatabase.encode(records).count <= SyncHTTPHandler.maximumBodyBytes / 2
        else { throw SyncHTTPError.resourceLimit }
        return (records, cursor)
    }

    static func preview(
        _ db: Database, incoming: [WebsiteIconRecord]?, captures: [UUID: SharedCapture]
    ) throws -> [WebsiteIconRecord]? {
        try decisions(db, incoming: incoming, captures: captures)?.records
    }
    static func cursor(
        _ db: Database, incoming: [WebsiteIconRecord]?, captures: [UUID: SharedCapture]
    ) throws -> Int64? {
        try decisions(db, incoming: incoming, captures: captures)?.cursor
    }
    static func apply(
        _ db: Database, records: [WebsiteIconRecord]?, cursor: Int64?, captureIDs: [UUID]
    ) throws {
        guard let records, let cursor else {
            guard
                try Bool.fetchOne(
                    db,
                    sql:
                        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_website_icon_origins')"
                ) == true
            else { return }
            let captures = try Set(captureIDs).sorted { $0.uuidString < $1.uuidString }.compactMap {
                try SyncDatabase.record(db, id: $0)
            }
            for capture in captures { try WebsiteIconDatabase.index(db, capture) }
            for capture in captures { try WebsiteIconDatabase.captureSaved(db, capture) }
            return
        }
        try WebsiteIconDatabase.prepare(db)
        for id in Set(captureIDs) {
            if let capture = try SyncDatabase.record(db, id: id) {
                try WebsiteIconDatabase.index(db, capture)
            }
        }
        for record in records {
            if try WebsiteIconDatabase.record(db, id: record.id) != record {
                try WebsiteIconDatabase.save(db, record)
                try WebsiteIconDatabase.append(
                    db, WebsiteIconFeedChange(cursor: record.revision, record: record))
            }
        }
        try db.execute(
            sql:
                "DELETE FROM sync_website_icon_feed; UPDATE sync_website_icon_meta SET cursor=?,floor=?",
            arguments: [cursor, cursor])
    }
}
