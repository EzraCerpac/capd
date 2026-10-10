import CapdSync
import Foundation
import GRDB

public struct WebsiteIconClaim: Equatable, Sendable {
    public let origin: WebsiteIconOrigin
    public let token: UUID
    public let normalizerVersion: Int
    let binding: SyncLibraryBinding?
    let deviceID: UUID?
}

public enum WebsiteIconFetchOutcome: Sendable {
    case normalizedPNG(Data)
    case missing
}

extension Store {
    public func websiteIcon(for url: String) throws -> WebsiteIconRecord? {
        guard let origin = WebsiteIconOrigin(url: url) else { return nil }
        return try reader.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT content,revision FROM website_icon_jobs WHERE id=? AND content IS NOT NULL AND EXISTS(SELECT 1 FROM capture_icon_origins WHERE origin_id=website_icon_jobs.id)",
                    arguments: [origin.id])
            else { return nil }
            return WebsiteIconRecord(
                origin: origin, revision: row["revision"],
                content: try JSONDecoder().decode(WebsiteIconContent.self, from: row["content"]))
        }
    }

    public func verifiedWebsiteIconData(_ record: WebsiteIconRecord) throws -> Data {
        try record.validate()
        guard !record.deleted, let content = record.content else { throw SyncError.blobMissing }
        let binding = try reader.read { try StoreSync.binding(in: $0) }
        let directory = paths.assetsDirectory.appendingPathComponent(
            binding == nil ? "website-icons" : "sync")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw SyncError.blobMissing
        }
        let data = try BlobStore(directory: directory, binding: binding).read(content.blob)
        try WebsiteIconService.validatePNG(data)
        return data
    }

    public func storedWebsiteIcons() throws -> [WebsiteIconRecord] {
        try reader.read(Self.websiteIconRecords(in:))
    }

    /// Live origins with no icon authority yet; tombstones and pending synced replacements block fallback.
    public func legacyWebsiteIconOrigins() throws -> [WebsiteIconOrigin] {
        try reader.read { db in
            let hasIcons = try db.tableExists("sync_website_icon_records")
            let blocked =
                hasIcons
                ? try String.fetchSet(
                    db,
                    sql:
                        "SELECT id FROM sync_website_icon_records UNION SELECT id FROM sync_website_icon_visible"
                )
                : []
            return try Row.fetchAll(
                db,
                sql:
                    "SELECT id,origin FROM website_icon_jobs WHERE content IS NULL AND revision=0 AND EXISTS(SELECT 1 FROM capture_icon_origins WHERE origin_id=website_icon_jobs.id) ORDER BY id"
            ).compactMap { row in
                guard !blocked.contains(row["id"]) else { return nil }
                return WebsiteIconOrigin(url: row["origin"])
            }
        }
    }

    static func websiteIconRecords(in db: Database) throws -> [WebsiteIconRecord] {
        try Row.fetchAll(
            db,
            sql:
                "SELECT origin,content,revision FROM website_icon_jobs WHERE content IS NOT NULL AND EXISTS(SELECT 1 FROM capture_icon_origins WHERE origin_id=website_icon_jobs.id) ORDER BY id"
        ).map { row in
            guard let origin = WebsiteIconOrigin(url: row["origin"]) else {
                throw SyncError.invalidOperation
            }
            return WebsiteIconRecord(
                origin: origin, revision: row["revision"],
                content: try JSONDecoder().decode(WebsiteIconContent.self, from: row["content"]))
        }
    }

    public func refreshWebsiteIconsFromSync() throws {
        guard let client = syncClient else { return }
        let records = try client.websiteIcons(includeDeleted: true)
        for record in records {
            try record.validate()
            if !record.deleted, let content = record.content {
                try WebsiteIconService.validatePNG(client.blobs.read(content.blob))
            }
            try write { db in
                guard try client.websiteIcon(in: db, originID: record.id) == record else { return }
                try Self.projectWebsiteIcon(in: db, record: record)
            }
        }
    }

    static func projectWebsiteIcon(in db: Database, record: WebsiteIconRecord) throws {
        try record.validate()
        if record.deleted {
            try db.execute(
                sql:
                    "UPDATE website_icon_jobs SET content=NULL,revision=?,state='pending',claim=NULL,claimed_at=NULL WHERE id=? AND revision<=?",
                arguments: [record.revision, record.id, record.revision])
        } else if let content = record.content {
            try db.execute(
                sql:
                    "INSERT INTO website_icon_jobs(id,origin,state,retry_after,attempts,content,revision) VALUES(?,?,'succeeded',0,0,?,?) ON CONFLICT(id) DO UPDATE SET content=excluded.content,revision=excluded.revision,state='succeeded',claim=NULL,claimed_at=NULL WHERE website_icon_jobs.revision<=excluded.revision",
                arguments: [
                    record.id, record.origin.canonicalHTTPSOrigin,
                    try JSONEncoder().encode(content), record.revision,
                ])
        }
    }

    public func websiteIconsEnabled() throws -> Bool {
        try reader.read { try Self.websiteIconsEnabled(in: $0) }
    }

    public func setWebsiteIconsEnabled(_ enabled: Bool) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE website_icon_policy SET enabled=? WHERE id=1", arguments: [enabled])
            if !enabled {
                try db.execute(
                    sql:
                        "UPDATE website_icon_jobs SET state='pending',claim=NULL,claimed_at=NULL WHERE state='claimed'"
                )
            }
        }
    }

    public func websiteIconRecords() -> AsyncValueObservation<[WebsiteIconRecord]> {
        ValueObservation.tracking(Self.websiteIconRecords(in:)).values(in: dbPool)
    }

    public func claimNextWebsiteIcon(now: Date = Date()) throws -> WebsiteIconClaim? {
        try write { db in
            guard try Self.websiteIconsEnabled(in: db),
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT id,origin FROM website_icon_jobs WHERE state IN ('pending','retry','missing') AND retry_after<=? AND EXISTS(SELECT 1 FROM capture_icon_origins WHERE origin_id=website_icon_jobs.id) ORDER BY retry_after,id LIMIT 1",
                    arguments: [now]),
                let origin = WebsiteIconOrigin(url: row["origin"])
            else { return nil }
            let token = UUID()
            try db.execute(
                sql:
                    "UPDATE website_icon_jobs SET state='claimed',claim=?,claimed_at=?,attempts=MIN(attempts+1,1000000) WHERE id=?",
                arguments: [token.uuidString, now, origin.id])
            return WebsiteIconClaim(
                origin: origin, token: token, normalizerVersion: 1, binding: syncClient?.binding,
                deviceID: syncClient?.deviceID)
        }
    }

    public func reclaimStaleWebsiteIconClaims(now: Date = Date(), age: TimeInterval = 60) throws
        -> Int
    {
        try write { db in
            try db.execute(
                sql:
                    "UPDATE website_icon_jobs SET state='pending',claim=NULL,claimed_at=NULL WHERE state='claimed' AND claimed_at<=?",
                arguments: [now.addingTimeInterval(-age)])
            return db.changesCount
        }
    }

    func finishWebsiteIcon(
        _ claim: WebsiteIconClaim, content: WebsiteIconContent?, missing: Bool, now: Date
    ) throws -> Bool {
        try write { db in
            guard try Self.websiteIconsEnabled(in: db),
                claim.binding == syncClient?.binding, claim.deviceID == syncClient?.deviceID,
                claim.normalizerVersion == 1,
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT attempts FROM website_icon_jobs WHERE id=? AND claim=? AND state='claimed' AND EXISTS(SELECT 1 FROM capture_icon_origins WHERE origin_id=website_icon_jobs.id)",
                    arguments: [claim.origin.id, claim.token.uuidString])
            else { return false }
            if let content {
                _ = try syncClient?.enqueueWebsiteIcon(
                    in: db, origin: claim.origin, mutation: .upsert(content))
                try db.execute(
                    sql:
                        "UPDATE website_icon_jobs SET state='succeeded',content=?,claim=NULL,claimed_at=NULL,retry_after=0 WHERE id=?",
                    arguments: [try JSONEncoder().encode(content), claim.origin.id])
            } else {
                let attempts: Int = row["attempts"]
                let delay =
                    missing
                    ? FaviconPolicy.missTTL : min(3600, 30 * pow(2, Double(min(attempts - 1, 7))))
                try db.execute(
                    sql:
                        "UPDATE website_icon_jobs SET state=?,claim=NULL,claimed_at=NULL,retry_after=? WHERE id=?",
                    arguments: [
                        missing ? "missing" : "retry", now.addingTimeInterval(delay),
                        claim.origin.id,
                    ])
            }
            return true
        }
    }

    func websiteIconClaimIsCurrent(_ claim: WebsiteIconClaim) throws -> Bool {
        try reader.read { db in
            try StoreSync.checkBinding(db, expected: claim.binding)
            return try Self.websiteIconsEnabled(in: db)
                && Bool.fetchOne(
                    db,
                    sql:
                        "SELECT EXISTS(SELECT 1 FROM website_icon_jobs WHERE id=? AND claim=? AND state='claimed' AND EXISTS(SELECT 1 FROM capture_icon_origins WHERE origin_id=website_icon_jobs.id))",
                    arguments: [claim.origin.id, claim.token.uuidString]) == true
        }
    }

    static func websiteIconsEnabled(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT enabled FROM website_icon_policy WHERE id=1") ?? false
    }

    static func reconcileWebsiteIconOrigin(in db: Database, captureID: Int64) throws {
        let row = try Row.fetchOne(
            db, sql: "SELECT kind,url FROM captures WHERE id=?", arguments: [captureID])
        let origin: WebsiteIconOrigin? = row.flatMap { row in
            guard row["kind"] as String == CaptureKind.link.rawValue, let url: String = row["url"]
            else { return nil }
            return WebsiteIconOrigin(url: url)
        }
        if let origin {
            try db.execute(
                sql:
                    "INSERT INTO website_icon_jobs(id,origin,state,retry_after,attempts) VALUES(?,?,'pending',0,0) ON CONFLICT(id) DO NOTHING",
                arguments: [origin.id, origin.canonicalHTTPSOrigin])
            try db.execute(
                sql:
                    "INSERT INTO capture_icon_origins(capture_id,origin_id) VALUES(?,?) ON CONFLICT(capture_id) DO UPDATE SET origin_id=excluded.origin_id",
                arguments: [captureID, origin.id])
        } else {
            try db.execute(
                sql: "DELETE FROM capture_icon_origins WHERE capture_id=?", arguments: [captureID])
        }
        try revokeUnreferencedWebsiteIconClaims(in: db)
    }

    static func revokeUnreferencedWebsiteIconClaims(in db: Database) throws {
        try db.execute(
            sql:
                "UPDATE website_icon_jobs SET state='pending',claim=NULL,claimed_at=NULL WHERE state='claimed' AND NOT EXISTS(SELECT 1 FROM capture_icon_origins WHERE origin_id=website_icon_jobs.id)"
        )
    }
}
