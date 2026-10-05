import CryptoKit
import Foundation
import GRDB

public struct MacDiscoveryCapture: Sendable {
    public let localID: Int64
    public let id: UUID
    public let title: String
    public let manualTags: [String]
    public let revision: Int64
}

public struct MacDiscoverySnapshot: Sendable {
    public let libraryID: UUID
    public let captures: [MacDiscoveryCapture]

    /// A complete bounded read-only snapshot. Never creates mappings, a sync client,
    /// credentials, or a missing library. Bound identities come from the projection.
    public static func load(paths: StoragePaths, localLibraryID: UUID) throws -> Self {
        let store = try MacLibrarySession.readOnlyStore(paths: paths)
        return try store.reader.read { db in
            let binding = try StoreSync.binding(in: db)
            let libraryID = binding?.libraryID ?? localLibraryID
            let fields =
                try binding == nil
                ? nativeFields(hasMappings: db.tableExists("sync_capture_ids"))
                : sharedFields(in: db)
            let base = "WITH fields AS (\(fields))"
            let count =
                try Int.fetchOne(
                    db, sql: "\(base) SELECT COUNT(*) FROM (SELECT 1 FROM fields LIMIT 1001)") ?? 0
            guard count <= 1000 else { throw MacDiscoveryError.snapshotTooLarge }
            guard
                try Int.fetchOne(
                    db, sql: "\(base) SELECT COUNT(*) FROM fields WHERE NOT valid_fields") == 0
            else { throw MacDiscoveryError.invalidIdentity }
            let projection = """
                \(base), discovery AS (
                    SELECT local_id, id, kind, title, host, url, tags, revision,
                           CASE WHEN length(CAST(selection AS BLOB)) <= 4096 THEN selection
                                ELSE substr(selection, 1, 1024) END AS selection_prefix,
                           COALESCE(length(CAST(selection AS BLOB)) > 4096, 0) AS truncated
                    FROM fields)
                """
            let sizeSQL = """
                \(projection), sizes AS (
                    SELECT COALESCE(length(CAST(title AS BLOB)), 0) AS title_bytes,
                           COALESCE(length(CAST(host AS BLOB)), 0) AS host_bytes,
                           COALESCE(length(CAST(tags AS BLOB)), 0) AS tag_bytes,
                           COALESCE(length(CAST(id AS BLOB)), 0)
                             + length(CAST(kind AS BLOB))
                             + COALESCE(length(CAST(title AS BLOB)), 0)
                             + COALESCE(length(CAST(host AS BLOB)), 0)
                             + COALESCE(length(CAST(url AS BLOB)), 0)
                             + COALESCE(length(CAST(tags AS BLOB)), 0)
                             + COALESCE(length(CAST(selection_prefix AS BLOB)), 0) + 16 AS bytes
                    FROM discovery)
                SELECT COALESCE(MAX(title_bytes > 4096 OR host_bytes > 4096
                                     OR tag_bytes > 16384 OR bytes > 32768), 0) AS oversized,
                       COALESCE(SUM(bytes), 0) AS total FROM sizes
                """
            let sizes = try Row.fetchOne(db, sql: sizeSQL)!
            guard !(sizes["oversized"] as Bool), (sizes["total"] as Int) <= 8_388_608
            else { throw MacDiscoveryError.snapshotTooLarge }
            let rows = try Row.fetchAll(
                db, sql: "\(projection) SELECT * FROM discovery ORDER BY local_id LIMIT 1000")
            let captures = try rows.map { row -> MacDiscoveryCapture in
                let localID: Int64 = row["local_id"]
                let mapped: String? = row["id"]
                let id: UUID
                if let mapped, let uuid = UUID(uuidString: mapped) {
                    id = uuid
                } else {
                    guard binding == nil else { throw MacDiscoveryError.invalidIdentity }
                    let digest = Array(
                        SHA256.hash(data: Data("\(libraryID.uuidString):\(localID)".utf8)))
                    id = UUID(
                        uuid: (
                            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
                            digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
                            digest[12], digest[13], digest[14], digest[15]
                        ))
                }
                var title: String? = row["title"]
                if let selection: String = row["selection_prefix"] {
                    let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                    let truncated: Bool = row["truncated"]
                    // The next grapheme proves the eightieth cannot extend beyond the SQL prefix.
                    guard !truncated || trimmed.count > 80 else {
                        throw MacDiscoveryError.snapshotTooLarge
                    }
                    if title == String(trimmed.prefix(80)) { title = "Saved text" }
                }
                let tags: String? = row["tags"]
                let manual =
                    try binding == nil
                    ? (tags ?? "").split(separator: " ").map(String.init)
                    : JSONDecoder().decode([String].self, from: Data((tags ?? "[]").utf8))
                let host: String? = row["host"]
                let url: String? = row["url"]
                return MacDiscoveryCapture(
                    localID: localID, id: id,
                    title: title ?? host ?? url.flatMap(URL.init(string:))?.host ?? "Saved capture",
                    manualTags: manual, revision: row["revision"])
            }
            guard Set(captures.map(\.id)).count == captures.count else {
                throw MacDiscoveryError.invalidIdentity
            }
            return Self(libraryID: libraryID, captures: captures)
        }
    }

    private static func nativeFields(hasMappings: Bool) -> String {
        let mapped = hasMappings ? "i.global_id" : "NULL"
        let joins = hasMappings ? "LEFT JOIN sync_capture_ids i ON i.local_id=c.id" : ""
        let canonical =
            hasMappings
            ? """
            WHERE c.id IN (
                SELECT MIN(c2.id) FROM captures c2
                LEFT JOIN sync_capture_ids i2 ON i2.local_id=c2.id
                GROUP BY CASE WHEN \(uuidSQL("i2.global_id")) THEN UPPER(i2.global_id) ELSE c2.id END)
            """ : ""
        return """
            SELECT c.id AS local_id,
                   CASE WHEN \(uuidSQL(mapped)) THEN \(mapped) END AS id,
                   c.kind, c.title,
                   CASE WHEN c.title IS NULL THEN c.host END AS host,
                   CASE WHEN c.title IS NULL AND c.host IS NULL THEN c.url END AS url,
                   CASE WHEN c.kind='text' AND c.title IS NOT NULL THEN c.selection END AS selection,
                   CASE WHEN c.tags_version=-1 THEN c.tags END AS tags, 0 AS revision,
                   typeof(c.kind)='text' AND c.kind IN ('text','link','image')
                     AND \(textSQL("c.title")) AND typeof(c.tags_version)='integer'
                     AND (c.title IS NOT NULL OR \(textSQL("c.host")))
                     AND (c.title IS NOT NULL OR c.host IS NOT NULL OR \(textSQL("c.url")))
                     AND (c.kind!='text' OR c.title IS NULL OR \(textSQL("c.selection")))
                     AND (c.tags_version!=-1 OR \(textSQL("c.tags"))) AS valid_fields
            FROM captures c \(joins) \(canonical)
            """
    }

    private static func sharedFields(in db: Database) throws -> String {
        guard try db.tableExists("sync_capture_ids"), try db.tableExists("sync_aliases"),
            try db.tableExists("sync_visible")
        else { throw MacDiscoveryError.invalidIdentity }
        guard
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM captures c LEFT JOIN sync_capture_ids i ON i.local_id=c.id
                    WHERE NOT \(uuidSQL("i.global_id"))
                    """) == 0
        else { throw MacDiscoveryError.invalidIdentity }
        guard
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM captures c JOIN sync_capture_ids i ON i.local_id=c.id
                    LEFT JOIN sync_aliases a ON a.id=UPPER(i.global_id)
                    WHERE a.id IS NOT NULL AND NOT \(uuidSQL("a.canonical"))
                    """) == 0
        else { throw MacDiscoveryError.invalidIdentity }
        let canonical = """
            WITH canonical AS (
                SELECT COALESCE(a.canonical, UPPER(i.global_id)) AS id,
                       COALESCE(MIN(CASE WHEN UPPER(i.global_id)=UPPER(a.canonical)
                                          OR a.canonical IS NULL THEN c.id END), MIN(c.id)) AS local_id
                FROM captures c JOIN sync_capture_ids i ON i.local_id=c.id
                LEFT JOIN sync_aliases a ON a.id=UPPER(i.global_id)
                GROUP BY COALESCE(a.canonical, UPPER(i.global_id)))
            """
        let from = "FROM canonical c LEFT JOIN sync_visible v ON v.id=c.id"
        let raw = try Row.fetchOne(
            db,
            sql: """
                \(canonical) SELECT COALESCE(MAX(v.id IS NULL OR typeof(v.payload)!='blob'), 0) AS invalid,
                                    COALESCE(MAX(length(v.payload)), 0) AS largest,
                                    COALESCE(SUM(length(v.payload)), 0) AS total \(from)
                """)!
        guard !(raw["invalid"] as Bool) else { throw MacDiscoveryError.invalidIdentity }
        guard (raw["largest"] as Int) <= 16_777_216, (raw["total"] as Int) <= 67_108_864
        else { throw MacDiscoveryError.snapshotTooLarge }
        guard
            try Int.fetchOne(
                db,
                sql: """
                    \(canonical) SELECT COUNT(*) \(from) WHERE NOT json_valid(CAST(v.payload AS TEXT))
                    """) == 0
        else { throw MacDiscoveryError.invalidIdentity }
        let payload = "CAST(v.payload AS TEXT)"
        let id = "json_extract(\(payload), '$.id')"
        let deletedType = "json_type(\(payload), '$.deleted')"
        guard
            try Int.fetchOne(
                db,
                sql: """
                    \(canonical) SELECT COUNT(*) \(from)
                    WHERE NOT COALESCE(json_type(\(payload), '$.id')='text'
                                       AND \(id)=c.id COLLATE NOCASE
                                       AND \(deletedType) IN ('true','false'), 0)
                    """) == 0
        else { throw MacDiscoveryError.invalidIdentity }
        let kind = "json_extract(\(payload), '$.source.kind')"
        let title = "json_extract(\(payload), '$.source.title')"
        let host = "json_extract(\(payload), '$.source.host')"
        return """
            \(canonical) SELECT c.local_id, c.id, \(kind) AS kind, \(title) AS title,
                CASE WHEN \(title) IS NULL THEN \(host) END AS host,
                CASE WHEN \(title) IS NULL AND \(host) IS NULL
                     THEN json_extract(\(payload), '$.source.url') END AS url,
                CASE WHEN \(kind)='text' AND \(title) IS NOT NULL
                     THEN json_extract(\(payload), '$.source.selection') END AS selection,
                json_extract(\(payload), '$.manualTags') AS tags,
                json_extract(\(payload), '$.revision') AS revision,
                COALESCE(json_type(\(payload), '$.source')='object'
                  AND \(kind) IN ('text','link','image')
                  AND \(jsonTextSQL(payload, "$.source.title"))
                  AND (\(title) IS NOT NULL OR \(jsonTextSQL(payload, "$.source.host")))
                  AND (\(title) IS NOT NULL OR \(host) IS NOT NULL
                       OR \(jsonTextSQL(payload, "$.source.url")))
                  AND (\(kind)!='text' OR \(title) IS NULL
                       OR \(jsonTextSQL(payload, "$.source.selection")))
                  AND json_type(\(payload), '$.manualTags')='array'
                  AND json_type(\(payload), '$.revision')='integer'
                  AND json_extract(\(payload), '$.revision') >= 0, 0) AS valid_fields
            \(from) WHERE json_extract(\(payload), '$.deleted')=0
            """
    }

    private static func uuidSQL(_ column: String) -> String {
        """
        (CASE WHEN typeof(\(column))='text' AND length(CAST(\(column) AS BLOB))=36 THEN
            substr(\(column),9,1)='-' AND substr(\(column),14,1)='-'
            AND substr(\(column),19,1)='-' AND substr(\(column),24,1)='-'
            AND length(replace(\(column),'-',''))=32
            AND replace(\(column),'-','') NOT GLOB '*[^0-9a-fA-F]*' ELSE 0 END)
        """
    }

    private static func textSQL(_ column: String) -> String {
        "typeof(\(column)) IN ('null','text')"
    }

    private static func jsonTextSQL(_ payload: String, _ path: String) -> String {
        "(json_type(\(payload), '\(path)') IS NULL OR json_type(\(payload), '\(path)') IN ('null','text'))"
    }
}

public enum MacDiscoveryError: Error, LocalizedError {
    case snapshotTooLarge, invalidIdentity
    public var errorDescription: String? {
        switch self {
        case .snapshotTooLarge:
            "System search supports up to 1,000 captures within discovery size limits."
        case .invalidIdentity: "System search could not validate the library identities."
        }
    }
}
