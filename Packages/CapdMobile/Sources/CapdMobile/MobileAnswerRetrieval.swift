import CapdAnswers
import Foundation
import GRDB

/// Opens an existing projection read-only. It never runs migrations, opens a sync
/// client, fetches URLs, reads image assets, or adds work to the outbox.
public actor MobileAnswerRetrieval: AnswerRetrieving {
    private let database: DatabasePool
    private let access: MobileLibraryAccess?
    private static let substantiveProseSQL: String = {
        // SQLite's default trim omits tabs, newlines, and Unicode whitespace.
        let whitespace =
            "char(9,10,11,12,13,32,133,160,5760,8192,8193,8194,8195,8196,8197,8198,8199,8200,8201,8202,8203,8232,8233,8239,8287,12288)"
        return ["selection", "note", "body", "ocrText"].map {
            "length(trim(coalesce(mobile_captures.\($0), ''), \(whitespace))) > 0"
        }.joined(separator: " OR ")
    }()

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

    public func evidenceRevision() async throws -> String {
        let lease = try access?.lease()
        defer { withExtendedLifetime(lease) {} }
        try Task.checkCancellation()
        let revision = try await database.read { db in
            guard try db.tableExists("mobile_answer_evidence"),
                let revision = try String.fetchOne(
                    db, sql: "SELECT revision FROM mobile_answer_evidence WHERE id=1")
            else {
                throw AnswerError.libraryUpgradeRequired
            }
            return revision
        }
        try Task.checkCancellation()
        return revision
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
                        snippet(mobile_captures_fts, 1, '', '', '', 64) AS selectionExcerpt,
                        snippet(mobile_captures_fts, 1, char(1), '', '', 64) AS selectionHighlighted,
                        snippet(mobile_captures_fts, 2, '', '', '', 64) AS noteExcerpt,
                        snippet(mobile_captures_fts, 2, char(1), '', '', 64) AS noteHighlighted,
                        snippet(mobile_captures_fts, 5, '', '', '', 64) AS bodyExcerpt,
                        snippet(mobile_captures_fts, 5, char(1), '', '', 64) AS bodyHighlighted,
                        snippet(mobile_captures_fts, 6, '', '', '', 64) AS ocrTextExcerpt,
                        snippet(mobile_captures_fts, 6, char(1), '', '', 64) AS ocrTextHighlighted
                    FROM mobile_captures_fts
                    JOIN mobile_captures ON mobile_captures.localID = mobile_captures_fts.rowid
                    WHERE mobile_captures_fts MATCH ?
                        AND (\(substantiveProseSQL))
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
                WHERE \(matches) AND (\(substantiveProseSQL))\(exclusions)
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
                ? Self.fallbackExcerpt(prose)
                : Self.joinedExcerpt(fields)
            return AnswerEvidence(id: row["id"], title: row["title"], excerpt: excerpt)
        }
    }

    private static func excerpt(_ row: Row) -> String {
        let names = ["selection", "note", "body", "ocrText"]
        let prose = names.map { (row["\($0)Excerpt"] as String?) ?? "" }
        let fields = names.compactMap { field -> (text: String, matchOffset: Int)? in
            let text = (row["\(field)Excerpt"] as String?) ?? ""
            let highlighted = (row["\(field)Highlighted"] as String?) ?? ""
            guard text != highlighted else { return nil }
            return (text: text, matchOffset: zip(text, highlighted).prefix { $0 == $1 }.count)
        }
        return fields.isEmpty ? fallbackExcerpt(prose) : joinedExcerpt(fields)
    }

    private static func fallbackExcerpt(_ prose: [String]) -> String {
        let text =
            prose.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        return centeredExcerpt(text, matchOffset: 0, byteLimit: GroundedAnswerService.excerptLimit)
    }

    private static func joinedExcerpt(_ fields: [(text: String, matchOffset: Int)]) -> String {
        let separator = "\n\n"
        var remaining =
            GroundedAnswerService.excerptLimit - separator.utf8.count * (fields.count - 1)
        let excerpts = fields.enumerated().map { index, field in
            let limit = remaining / (fields.count - index)
            let excerpt = centeredExcerpt(
                field.text, matchOffset: field.matchOffset, byteLimit: limit)
            remaining -= excerpt.utf8.count
            return excerpt
        }
        return excerpts.joined(separator: separator)
    }

    private static func centeredExcerpt(_ text: String, matchOffset: Int, byteLimit: Int) -> String
    {
        let match = text.index(text.startIndex, offsetBy: min(matchOffset, text.count))
        var start = match
        var end = match
        var bytes = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            let cost = text[previous..<start].utf8.count
            guard bytes + cost <= byteLimit / 2 else { break }
            start = previous
            bytes += cost
        }
        while end < text.endIndex {
            let next = text.index(after: end)
            let cost = text[end..<next].utf8.count
            guard bytes + cost <= byteLimit else { break }
            end = next
            bytes += cost
        }
        while start > text.startIndex {
            let previous = text.index(before: start)
            let cost = text[previous..<start].utf8.count
            guard bytes + cost <= byteLimit else { break }
            start = previous
            bytes += cost
        }
        return String(text[start..<end])
    }
}
