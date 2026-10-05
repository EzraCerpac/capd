import Foundation
import GRDB

enum WebsiteIconDatabase {
    static let prefix = "sync_website_icon_"

    static func exists(_ db: Database) throws -> Bool { try db.tableExists(prefix + "meta") }

    static func prepare(_ db: Database) throws {
        if try exists(db) { return }
        try db.execute(
            sql: """
                CREATE TABLE sync_website_icon_meta (
                    id INTEGER PRIMARY KEY CHECK(id=1), sequence INTEGER NOT NULL DEFAULT 0,
                    cursor INTEGER NOT NULL DEFAULT 0, floor INTEGER NOT NULL DEFAULT 0,
                    observed_sequence INTEGER NOT NULL DEFAULT 0,
                    presentation_revision INTEGER NOT NULL DEFAULT 0);
                INSERT INTO sync_website_icon_meta(id) VALUES(1);
                CREATE TABLE sync_website_icon_records(id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE sync_website_icon_visible(id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE sync_website_icon_receipts(id TEXT PRIMARY KEY, operation BLOB NOT NULL, receipt BLOB NOT NULL);
                CREATE TABLE sync_website_icon_devices(id TEXT PRIMARY KEY, sequence INTEGER NOT NULL);
                CREATE TABLE sync_website_icon_feed(cursor INTEGER PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE sync_website_icon_outbox(sequence INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, origin TEXT UNIQUE NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE sync_website_icon_observed(id TEXT PRIMARY KEY);
                """)
        if try String.fetchOne(db, sql: "SELECT role FROM sync_meta") == "server" {
            try db.execute(
                sql: """
                    CREATE TABLE sync_website_icon_origins(capture TEXT PRIMARY KEY, origin TEXT NOT NULL, canonical TEXT NOT NULL, live INTEGER NOT NULL);
                    CREATE INDEX sync_website_icon_live_origins ON sync_website_icon_origins(origin,live);
                    """)
            let rows = try Data.fetchCursor(db, sql: "SELECT payload FROM sync_records ORDER BY id")
            while let data = try rows.next() {
                try index(db, SyncDatabase.decode(SharedCapture.self, data))
            }
        }
    }

    static func index(_ db: Database, _ capture: SharedCapture) throws {
        guard capture.source.kind == .link, let url = capture.source.url,
            let origin = WebsiteIconOrigin(url: url)
        else {
            try db.execute(
                sql: "DELETE FROM sync_website_icon_origins WHERE capture=?",
                arguments: [capture.id.uuidString])
            return
        }
        try db.execute(
            sql: """
                INSERT INTO sync_website_icon_origins(capture,origin,canonical,live) VALUES(?,?,?,?)
                ON CONFLICT(capture) DO UPDATE SET origin=excluded.origin,canonical=excluded.canonical,live=excluded.live
                """,
            arguments: [
                capture.id.uuidString, origin.id, origin.canonicalHTTPSOrigin, !capture.deleted,
            ])
    }

    static func captureSaved(_ db: Database, _ capture: SharedCapture) throws {
        guard try db.tableExists(prefix + "origins") else { return }
        let previous = try String.fetchOne(
            db, sql: "SELECT origin FROM sync_website_icon_origins WHERE capture=?",
            arguments: [capture.id.uuidString])
        try index(db, capture)
        let next =
            capture.source.kind == .link
            ? capture.source.url.flatMap { WebsiteIconOrigin(url: $0)?.id } : nil
        for id in Set([previous, next].compactMap { $0 }) {
            guard try !referenced(db, id), let record = try record(db, id: id), !record.deleted
            else { continue }
            let cursor = try nextCursor(db)
            let deleted = WebsiteIconRecord(
                origin: record.origin, revision: cursor, deleted: true, content: record.content)
            try save(db, deleted)
            try append(db, WebsiteIconFeedChange(cursor: cursor, record: deleted))
        }
    }

    static func referenced(_ db: Database, _ id: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sync_website_icon_origins WHERE origin=? AND live=1)",
            arguments: [id])!
    }

    static func record(_ db: Database, id: String, visible: Bool = false) throws
        -> WebsiteIconRecord?
    {
        guard try exists(db) else { return nil }
        return try Data.fetchOne(
            db, sql: "SELECT payload FROM \(prefix)\(visible ? "visible" : "records") WHERE id=?",
            arguments: [id]
        ).map { try SyncDatabase.decode(WebsiteIconRecord.self, $0) }
    }

    static func records(_ db: Database, visible: Bool = false) throws -> [WebsiteIconRecord] {
        guard try exists(db) else { return [] }
        return try Data.fetchAll(
            db, sql: "SELECT payload FROM \(prefix)\(visible ? "visible" : "records") ORDER BY id"
        ).map { try SyncDatabase.decode(WebsiteIconRecord.self, $0) }
    }

    static func save(_ db: Database, _ record: WebsiteIconRecord) throws {
        try record.validate()
        try db.execute(
            sql:
                "INSERT INTO sync_website_icon_records(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
            arguments: [record.id, try SyncDatabase.encode(record)])
    }

    static func nextCursor(_ db: Database) throws -> Int64 {
        let cursor = try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_website_icon_meta")!
        guard cursor < Int64.max else { throw SyncError.invalidCursor }
        return cursor + 1
    }

    static func append(_ db: Database, _ change: WebsiteIconFeedChange) throws {
        try db.execute(
            sql: "INSERT INTO sync_website_icon_feed(cursor,payload) VALUES(?,?)",
            arguments: [change.cursor, try SyncDatabase.encode(change)])
        try db.execute(
            sql: "UPDATE sync_website_icon_meta SET cursor=?", arguments: [change.cursor])
    }

    static func operations(_ db: Database) throws -> [WebsiteIconOperation] {
        guard try exists(db) else { return [] }
        return try Data.fetchAll(
            db, sql: "SELECT payload FROM sync_website_icon_outbox ORDER BY sequence"
        ).map { try SyncDatabase.decode(WebsiteIconOperation.self, $0) }
    }

    static func rebuild(_ db: Database) throws {
        let before = try records(db, visible: true)
        var records = Dictionary(uniqueKeysWithValues: try self.records(db).map { ($0.id, $0) })
        for operation in try operations(db) {
            let old = records[operation.origin.id]
            switch operation.mutation {
            case .upsert(let content):
                records[operation.origin.id] = WebsiteIconRecord(
                    origin: operation.origin, revision: old?.revision ?? 0, content: content)
            case .tombstone:
                records[operation.origin.id] = WebsiteIconRecord(
                    origin: operation.origin, revision: old?.revision ?? 0, deleted: true,
                    content: old?.content)
            }
        }
        let after = records.values.sorted { $0.id < $1.id }
        if before == after { return }
        let epoch = try Int64.fetchOne(
            db, sql: "SELECT presentation_revision FROM sync_website_icon_meta")!
        guard epoch < Int64.max else { throw SyncError.invalidCursor }
        try db.execute(sql: "DELETE FROM sync_website_icon_visible")
        for record in after {
            try db.execute(
                sql: "INSERT INTO sync_website_icon_visible(id,payload) VALUES(?,?)",
                arguments: [record.id, try SyncDatabase.encode(record)])
        }
        try db.execute(
            sql: "UPDATE sync_website_icon_meta SET presentation_revision=?", arguments: [epoch + 1]
        )
    }
}
