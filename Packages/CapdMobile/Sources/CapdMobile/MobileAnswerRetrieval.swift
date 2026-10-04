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

    init(database: DatabasePool) {
        self.database = database
        access = nil
    }

    public func search(_ query: String, limit: Int) async throws -> [AnswerEvidence] {
        try await search([query], limit: limit)[0]
    }

    public func search(_ queries: [String], limit: Int) async throws -> [[AnswerEvidence]] {
        let lease = try access?.lease()
        defer { withExtendedLifetime(lease) {} }
        try Task.checkCancellation()
        let results = try await database.read { db in
            try queries.map { query in
                try Task.checkCancellation()
                return try Self.search(query, limit: limit, in: db)
            }
        }
        try Task.checkCancellation()
        return results
    }

    private static func search(_ query: String, limit: Int, in db: Database) throws
        -> [AnswerEvidence]
    {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let cap = min(limit, 12)
        let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
        let literalTerms = Self.literalTerms(query)
        guard pattern != nil || !literalTerms.isEmpty else { return [] }
        // Match and snippet use the same tokenizer, including Porter stemming.
        // Titles can find sources, but excerpts must come from saved prose.
        var evidence: [AnswerEvidence] = []
        if let pattern {
            let prosePattern = "{title selection note body ocrText} : (\(pattern.rawPattern))"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT mobile_captures.id, mobile_captures.title,
                        CASE WHEN highlight(mobile_captures_fts, 1, '', '|') != mobile_captures.selection
                            THEN snippet(mobile_captures_fts, 1, '', '', '', 64) END AS selectionExcerpt,
                        snippet(mobile_captures_fts, 1, char(1), '', '', 64) AS selectionHighlighted,
                        CASE WHEN highlight(mobile_captures_fts, 2, '', '|') != mobile_captures.note
                            THEN snippet(mobile_captures_fts, 2, '', '', '', 64) END AS noteExcerpt,
                        snippet(mobile_captures_fts, 2, char(1), '', '', 64) AS noteHighlighted,
                        CASE WHEN highlight(mobile_captures_fts, 5, '', '|') != coalesce(mobile_captures.body, '')
                            THEN snippet(mobile_captures_fts, 5, '', '', '', 64) END AS bodyExcerpt,
                        snippet(mobile_captures_fts, 5, char(1), '', '', 64) AS bodyHighlighted,
                        CASE WHEN highlight(mobile_captures_fts, 6, '', '|') != coalesce(mobile_captures.ocrText, '')
                            THEN snippet(mobile_captures_fts, 6, '', '', '', 64) END AS ocrTextExcerpt,
                        snippet(mobile_captures_fts, 6, char(1), '', '', 64) AS ocrTextHighlighted,
                        snippet(mobile_captures_fts,
                            CASE
                                WHEN length(mobile_captures.selection) > 0 THEN 1
                                WHEN length(mobile_captures.note) > 0 THEN 2
                                WHEN length(coalesce(mobile_captures.body, '')) > 0 THEN 5
                                ELSE 6
                            END, '', '', '', 64) AS fallbackExcerpt
                    FROM mobile_captures_fts
                    JOIN mobile_captures ON mobile_captures.localID = mobile_captures_fts.rowid
                    WHERE mobile_captures_fts MATCH ?
                        AND length(mobile_captures.selection || mobile_captures.note ||
                            coalesce(mobile_captures.body, '') || coalesce(mobile_captures.ocrText, '')) > 0
                    ORDER BY bm25(mobile_captures_fts), mobile_captures.createdAt DESC,
                        mobile_captures.localID DESC LIMIT ?
                    """, arguments: [prosePattern, cap])
            evidence = rows.map { row in
                AnswerEvidence(
                    id: row["id"], title: row["title"], excerpt: Self.excerpt(row))
            }
        }
        guard !literalTerms.isEmpty, evidence.count < cap else { return evidence }
        return evidence
            + (try Self.literalEvidence(
                db, terms: literalTerms, excluding: evidence.map(\.id),
                limit: cap - evidence.count))
    }

    private static func literalTerms(_ query: String) -> [String] {
        guard query.count <= 500 else { return [] }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard terms.count <= 8,
            terms.contains(where: { term in
                term.contains { $0.isLetter && !$0.isASCII }
            })
        else { return [] }
        return terms
    }

    private static func literalEvidence(
        _ db: Database, terms: [String], excluding ids: [String], limit: Int
    ) throws -> [AnswerEvidence] {
        let prose = "selection || note || coalesce(body, '') || coalesce(ocrText, '')"
        let text =
            "title || char(10) || selection || char(10) || note || char(10) || coalesce(body, '') || char(10) || coalesce(ocrText, '')"
        let matches = terms.map { _ in "instr(lower(\(text)), lower(?)) > 0" }.joined(
            separator: " AND ")
        let exclusions =
            ids.isEmpty ? "" : " AND id NOT IN (\(ids.map { _ in "?" }.joined(separator: ",")))"
        var arguments = StatementArguments(terms + ids)
        arguments += [limit]
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, title, selection, note, body, ocrText FROM mobile_captures
                WHERE \(matches) AND length(\(prose)) > 0\(exclusions)
                ORDER BY createdAt DESC, localID DESC LIMIT ?
                """, arguments: arguments)
        return rows.map { row in
            let prose = ["selection", "note", "body", "ocrText"].compactMap { field in
                row[field] as String?
            }
            let fields = prose.compactMap { text -> (text: String, matchOffset: Int)? in
                let offsets = terms.compactMap { term in
                    text.range(of: term, options: .caseInsensitive).map {
                        text.distance(from: text.startIndex, to: $0.lowerBound)
                    }
                }
                guard let offset = offsets.min() else { return nil }
                return (text: text, matchOffset: offset)
            }
            let excerpt =
                fields.isEmpty
                ? String(
                    (prose.first { !$0.isEmpty } ?? "").prefix(GroundedAnswerService.excerptLimit))
                : Self.joinedExcerpt(fields)
            return AnswerEvidence(id: row["id"], title: row["title"], excerpt: excerpt)
        }
    }

    private static func excerpt(_ row: Row) -> String {
        let fields = ["selection", "note", "body", "ocrText"].compactMap {
            field -> (
                text: String, matchOffset: Int
            )? in
            guard let text: String = row["\(field)Excerpt"] else { return nil }
            let highlighted: String = row["\(field)Highlighted"]
            return (text: text, matchOffset: zip(text, highlighted).prefix { $0 == $1 }.count)
        }
        guard !fields.isEmpty else {
            return String(
                (row["fallbackExcerpt"] as String).prefix(GroundedAnswerService.excerptLimit))
        }
        return joinedExcerpt(fields)
    }

    private static func joinedExcerpt(_ fields: [(text: String, matchOffset: Int)]) -> String {
        let separator = "\n\n"
        var remaining = GroundedAnswerService.excerptLimit - separator.count * (fields.count - 1)
        let excerpts = fields.enumerated().map { index, field in
            let limit = remaining / (fields.count - index)
            let start = max(0, min(field.matchOffset - limit / 2, field.text.count - limit))
            let excerpt = String(field.text.dropFirst(start).prefix(limit))
            remaining -= excerpt.count
            return excerpt
        }
        return excerpts.joined(separator: separator)
    }
}
