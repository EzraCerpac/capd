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
            // Restrict evidence to saved prose; tags alone cannot support an answer.
            let prosePattern = "{title selection note body ocrText} : (\(pattern.rawPattern))"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT mobile_captures.id, mobile_captures.title,
                        snippet(mobile_captures_fts, -1, '', '', ' … ', 64) AS excerpt
                    FROM mobile_captures_fts
                    JOIN mobile_captures ON mobile_captures.localID = mobile_captures_fts.rowid
                    WHERE mobile_captures_fts MATCH ?
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
