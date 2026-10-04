import CapdAnswers
import Foundation
import GRDB

/// Opens an existing projection read-only. It never runs migrations, opens a sync
/// client, fetches URLs, reads image assets, or adds work to the outbox.
public actor MobileAnswerRetrieval: AnswerRetrieving {
    private let database: DatabasePool
    private let access: MobileLibraryAccess?

    public init(databaseURL: URL, access: MobileLibraryAccess? = nil) throws {
        self.access = access
        let lease = try access?.lease()
        defer { withExtendedLifetime(lease) {} }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(2)
        database = try DatabasePool(path: databaseURL.path, configuration: configuration)
    }

    public func search(_ query: String, limit: Int) async throws -> [AnswerEvidence] {
        let lease = try access?.lease()
        defer { withExtendedLifetime(lease) {} }
        try Task.checkCancellation()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let cap = min(limit, 12)
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        let evidence = try await database.read { db in
            // Match and snippet use the same tokenizer, including Porter stemming.
            // Titles can find sources, but excerpts must come from saved prose.
            let prosePattern = "{title selection note body ocrText} : (\(pattern.rawPattern))"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT mobile_captures.id, mobile_captures.title,
                        snippet(mobile_captures_fts,
                            CASE
                                WHEN highlight(mobile_captures_fts, 1, '', '|') != mobile_captures.selection THEN 1
                                WHEN highlight(mobile_captures_fts, 2, '', '|') != mobile_captures.note THEN 2
                                WHEN highlight(mobile_captures_fts, 5, '', '|') != coalesce(mobile_captures.body, '') THEN 5
                                WHEN highlight(mobile_captures_fts, 6, '', '|') != coalesce(mobile_captures.ocrText, '') THEN 6
                                WHEN length(mobile_captures.selection) > 0 THEN 1
                                WHEN length(mobile_captures.note) > 0 THEN 2
                                WHEN length(coalesce(mobile_captures.body, '')) > 0 THEN 5
                                ELSE 6
                            END, '', '', '', 64) AS excerpt
                    FROM mobile_captures_fts
                    JOIN mobile_captures ON mobile_captures.localID = mobile_captures_fts.rowid
                    WHERE mobile_captures_fts MATCH ?
                        AND length(mobile_captures.selection || mobile_captures.note ||
                            coalesce(mobile_captures.body, '') || coalesce(mobile_captures.ocrText, '')) > 0
                    ORDER BY bm25(mobile_captures_fts), mobile_captures.createdAt DESC,
                        mobile_captures.localID DESC LIMIT ?
                    """, arguments: [prosePattern, cap])
            return rows.map { row in
                AnswerEvidence(
                    id: row["id"], title: row["title"],
                    excerpt: String(
                        (row["excerpt"] as String).prefix(GroundedAnswerService.excerptLimit)))
            }
        }
        try Task.checkCancellation()
        return evidence
    }
}
