import CapdAnswers
import Foundation
import GRDB
import Testing

@testable import CapdMobile

@Test(arguments: ["蘭に必要な光は何ですか", "兰花需要什么光照"])
func localAnswerQuestionsCiteMidSentenceNonSpaceEvidence(question: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-language-question-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let quote =
        question.contains("蘭")
        ? "蘭には明るい間接光が適しています。" : "兰花适合明亮的间接光照。"
    let saved = MobileCapture(
        kind: .text, title: "Saved observations",
        selection: "保存した植物についてのメモには\(quote)と記載しています。")
    try mobile.save(saved)
    let before = try mobile.capture(id: saved.id)
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let result = try await GroundedAnswerService(
        retriever: reader, model: LiteralEvidenceQuoteModel(quote: quote)
    ).answer(question)
    #expect(result.sources.map { $0.source.id } == [saved.id.uuidString])
    #expect(result.sources.first?.source.excerpt.contains(quote) == true)
    #expect(result.statements.first?.citations.first?.quote == quote)
    #expect(try mobile.capture(id: saved.id) == before)
    #expect(try mobile.pending() == pending)
}

private struct LiteralEvidenceQuoteModel: AnswerGenerating {
    let quote: String
    func availability() -> AnswerAvailability { .available }
    func answer(question: String, sources: [NumberedEvidence]) async throws -> AnswerDraft {
        AnswerDraft(statements: [
            .init(
                text: "Synthetic supported statement", citations: [.init(number: 1, quote: quote)])
        ])
    }
}

@Test(arguments: ["water orchid", "WATER ORCHID"])
func localAnswerRetrievalCombinesSelectionAndBodyForAllTerms(query: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-fields-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let saved = MobileCapture(
        kind: .text, title: "Saved plant observations", selection: "An orchid overview.",
        note: "An unrelated saved observation.")
    try mobile.save(saved)
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
        try db.execute(
            sql: "UPDATE mobile_captures SET body = ?, ocrText = ? WHERE id = ?",
            arguments: [
                "Water orchids weekly.", "Another unrelated observation.", saved.id.uuidString,
            ])
    }
    let before = try mobile.capture(id: saved.id)
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try #require(try await reader.search(query, limit: 1).first)
    #expect(evidence.id == saved.id.uuidString)
    #expect(evidence.excerpt == "An orchid overview.\n\nWater orchids weekly.")
    #expect(try mobile.capture(id: saved.id) == before)
    #expect(try mobile.pending() == pending)
}

@Test func localAnswerRetrievalSharesTheExcerptBudgetAcrossAllMatchingFields() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-field-budget-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let fields = ["selection", "note", "body", "OCR"]
    let prose = fields.map { field in
        String(repeating: "Synthetic introductory context. ", count: 80)
            + "Orchids grow in the \(field) passage. "
            + String(repeating: "Synthetic concluding context. ", count: 80)
    }
    let saved = MobileCapture(
        kind: .text, title: "Saved growing observations", selection: prose[0], note: prose[1])
    try mobile.save(saved)
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
        try db.execute(
            sql: "UPDATE mobile_captures SET body = ?, ocrText = ? WHERE id = ?",
            arguments: [prose[2], prose[3], saved.id.uuidString])
    }
    let before = try mobile.capture(id: saved.id)
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try #require(try await reader.search("orchid", limit: 1).first)
    let excerpts = evidence.excerpt.components(separatedBy: "\n\n")
    #expect(evidence.id == saved.id.uuidString)
    #expect(evidence.excerpt.count <= GroundedAnswerService.excerptLimit)
    #expect(excerpts.count == fields.count)
    for (index, excerpt) in excerpts.prefix(fields.count).enumerated() {
        #expect(prose[index].contains(excerpt))
        #expect(excerpt.contains("Orchids grow in the \(fields[index]) passage."))
    }
    #expect(try mobile.capture(id: saved.id) == before)
    #expect(try mobile.pending() == pending)
}

@Test func localAnswerRetrievalKeepsTheSavedProseFallbackForTitleOnlyMatches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-field-fallback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let saved = MobileCapture(
        kind: .text, title: "Orchid guide", selection: "A saved selection observation.",
        note: "A separate saved note.")
    try mobile.save(saved)
    let before = try mobile.capture(id: saved.id)
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try #require(try await reader.search("orchid", limit: 1).first)
    #expect(evidence.id == saved.id.uuidString)
    #expect(evidence.excerpt == saved.selection)
    #expect(try mobile.capture(id: saved.id) == before)
    #expect(try mobile.pending() == pending)
}

@Test(arguments: ["水やり", "浇水"])
func localAnswerRetrievalFindsLiteralWordsInsideContinuousSavedProse(query: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-literal-fields-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let context = query == "水やり" ? "これは保存した文章の前置きです" : "这是保存下来的文字内容"
    let fields = ["selection", "note", "body", "OCR"]
    let prose = fields.map { field in
        String(repeating: context, count: 150)
            + "\(query)の\(field)記録"
            + String(repeating: context, count: 150)
    }
    let saved = MobileCapture(
        kind: .text, title: "Saved observations", selection: prose[0], note: prose[1])
    try mobile.save(saved)
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
        try db.execute(
            sql: "UPDATE mobile_captures SET body = ?, ocrText = ? WHERE id = ?",
            arguments: [prose[2], prose[3], saved.id.uuidString])
    }
    let before = try mobile.capture(id: saved.id)
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try #require(try await reader.search(query, limit: 1).first)
    let excerpts = evidence.excerpt.components(separatedBy: "\n\n")
    #expect(evidence.id == saved.id.uuidString)
    #expect(evidence.excerpt.count <= GroundedAnswerService.excerptLimit)
    #expect(excerpts.count == fields.count)
    for (index, excerpt) in excerpts.prefix(fields.count).enumerated() {
        #expect(prose[index].contains(excerpt))
        #expect(excerpt.contains("\(query)の\(fields[index])記録"))
    }
    #expect(try mobile.capture(id: saved.id) == before)
    #expect(try mobile.pending() == pending)
}

@Test func localAnswerLiteralRetrievalRequiresAllTermsAcrossTitleAndProse() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-literal-terms-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let saved = MobileCapture(
        kind: .text, title: "保存した温室の管理", selection: "記録によると毎週少量の水を与えます")
    try mobile.save(saved)
    try mobile.save(
        MobileCapture(kind: .text, title: "保存した温室の管理", selection: "明るい場所に置きます"))
    try mobile.save(MobileCapture(kind: .link, title: "保存した温室で毎週作業します"))
    let before = try mobile.search()
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try await reader.search("温室 毎週", limit: 12)
    #expect(evidence.map(\.id) == [saved.id.uuidString])
    #expect(evidence.first?.excerpt == saved.selection)
    #expect(try mobile.search() == before)
    #expect(try mobile.pending() == pending)
}

@Test func localAnswerLiteralRetrievalTreatsPunctuationAsLiteralText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-literal-punctuation-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let saved = MobileCapture(
        kind: .text, title: "Saved measurement", selection: "この記録は測定温度_%'の値を保存しています")
    try mobile.save(saved)
    try mobile.save(
        MobileCapture(
            kind: .text, title: "Saved other measurement",
            selection: "この記録は測定温度ABの値を保存しています"))
    let before = try mobile.search()
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try await reader.search("温度_%'", limit: 12)
    #expect(evidence.map(\.id) == [saved.id.uuidString])
    #expect(evidence.first?.excerpt == saved.selection)
    #expect(try mobile.search() == before)
    #expect(try mobile.pending() == pending)
}

@Test func localAnswerLiteralRetrievalKeepsSavedProseForTitleOnlyMatches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-literal-title-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let saved = MobileCapture(
        kind: .text, title: "这个记录包含浇水建议", selection: "A saved observation about shadows.",
        note: "Another saved observation.")
    try mobile.save(saved)
    let before = try mobile.capture(id: saved.id)
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try #require(try await reader.search("浇水", limit: 1).first)
    #expect(evidence.id == saved.id.uuidString)
    #expect(evidence.excerpt == saved.selection)
    #expect(try mobile.capture(id: saved.id) == before)
    #expect(try mobile.pending() == pending)
}

@Test func localAnswerLiteralRetrievalFillsSlotsAfterFTSWithoutDuplicateSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-literal-ranking-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let first = MobileCapture(kind: .text, title: "Saved guide", selection: "水やり weekly.")
    try mobile.save(first)
    for index in 0..<15 {
        try mobile.save(
            MobileCapture(
                kind: .text, title: "Saved observations",
                selection: "今日は水やりのsyntheticcare記録\(index)を保存します"))
    }
    let before = try mobile.search()
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try await reader.search("水やり", limit: 100)
    #expect(evidence.first?.id == first.id.uuidString)
    #expect(evidence.count == 12)
    #expect(Set(evidence.map(\.id)).count == evidence.count)
    #expect(try await reader.search("水やり", limit: 1).map(\.id) == [first.id.uuidString])
    #expect(try await reader.search("care", limit: 12).isEmpty)
    #expect(try mobile.search() == before)
    #expect(try mobile.pending() == pending)
}

@Test(arguments: ["水やり", "浇水"])
func localAnswerCenteredMultibyteExcerptsRetainMatchedQuotesWithinByteBudget(query: String)
    async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-byte-centered-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let quote = "\(query)の記録には毎週少量の水を与えます"
    let context = "これは保存した文章の前置きです"
    let prose =
        String(repeating: context, count: 150) + quote
        + String(repeating: context, count: 150)
    let saved = MobileCapture(kind: .text, title: "Saved observations", selection: prose)
    try mobile.save(saved)
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try #require(try await reader.search(query, limit: 1).first)
    #expect(evidence.excerpt.utf8.count <= GroundedAnswerService.excerptLimit)
    #expect(evidence.excerpt.contains(quote))
    let answer = try await GroundedAnswerService(
        retriever: reader, model: LiteralEvidenceQuoteModel(quote: quote)
    ).answer(query)
    #expect(answer.sources.first?.source.excerpt.contains(quote) == true)
    #expect(answer.statements.first?.citations.first?.quote == quote)
    #expect(try mobile.pending() == pending)
}

@Test(arguments: [false, true])
func localAnswerWhitespaceOnlyTitleMatchesDoNotConsumeHitLimit(literal: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-whitespace-limit-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let query = literal ? "温室" : "orchid"
    let title = literal ? "保存した温室の管理" : "Orchid"
    let quote = "Saved observations describe a river crossing."
    let saved = MobileCapture(
        kind: .text, title: title + " saved observations", selection: quote)
    try mobile.save(saved)
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
        for _ in 0..<12 {
            var blank = MobileCapture(
                kind: .link, title: title, selection: " \t\n\r\u{B}\u{C}",
                note: "\u{85}\u{A0}\u{1680}")
            blank.body = "\u{2000}\u{200B}\u{2028}\u{2029}"
            blank.ocrText = "\u{202F}\u{205F}\u{3000}"
            try blank.insert(db)
        }
    }
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try await reader.search(query, limit: 12)
    #expect(evidence.map(\.id) == [saved.id.uuidString])
    #expect(evidence.first?.excerpt == quote)
    let answer = try await GroundedAnswerService(
        retriever: reader, model: LiteralEvidenceQuoteModel(quote: quote)
    ).answer(query)
    #expect(answer.sources.map { $0.source.id } == [saved.id.uuidString])
    #expect(try mobile.pending() == pending)
}

@Test(arguments: [false, true])
func localAnswerTitleFallbackSkipsWhitespaceOnlyEarlierFields(literal: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-whitespace-fallback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let query = literal ? "温室" : "orchid"
    let quote = "Saved observations describe a river crossing."
    let saved = MobileCapture(
        kind: .text, title: literal ? "保存した温室の管理" : "Orchid guide",
        selection: " \t\n ", note: "\t \u{3000}")
    try mobile.save(saved)
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
        try db.execute(
            sql: "UPDATE mobile_captures SET body=? WHERE id=?",
            arguments: [quote, saved.id.uuidString])
    }
    let pending = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try #require(try await reader.search(query, limit: 1).first)
    #expect(evidence.excerpt == quote)
    let answer = try await GroundedAnswerService(
        retriever: reader, model: LiteralEvidenceQuoteModel(quote: quote)
    ).answer(query)
    #expect(answer.sources.first?.source.id == saved.id.uuidString)
    #expect(try mobile.pending() == pending)
}

@Test func localAnswerMatchingFieldsUseSnippetsWithoutFullColumnHighlightCalls() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-bounded-matches-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let quote = "Orchids grow in the saved passage."
    let prose =
        String(repeating: "Synthetic introductory context. ", count: 512) + quote
        + String(repeating: "Synthetic concluding context. ", count: 512)
    let saved = MobileCapture(kind: .text, title: "Saved observations", selection: prose)
    try mobile.save(saved)
    let trace = AnswerQueryTrace()
    var config = Configuration()
    config.readonly = true
    config.prepareDatabase { db in
        db.trace { trace.append($0.description) }
    }
    let database = try DatabasePool(path: url.path, configuration: config)
    let reader = MobileAnswerRetrieval(database: database)
    let evidence = try #require(try await reader.search("orchid", limit: 1).first)
    #expect(evidence.excerpt.contains(quote))
    #expect(evidence.excerpt.utf8.count <= GroundedAnswerService.excerptLimit)
    #expect(!trace.usesFullColumnHighlight)
}

@Test func localAnswerSnippetMarkersDoNotAlterSavedControlCharacters() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-verbatim-markers-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let quote = "Saved \u{1}orchid care uses filtered light."
    try mobile.save(MobileCapture(kind: .text, title: "Saved observations", selection: quote))
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    #expect(try await reader.search("orchid", limit: 1).first?.excerpt == quote)
    let answer = try await GroundedAnswerService(
        retriever: reader, model: LiteralEvidenceQuoteModel(quote: quote)
    ).answer("orchid")
    #expect(answer.statements.first?.citations.first?.quote == quote)
}

private final class AnswerQueryTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []
    var usesFullColumnHighlight: Bool {
        lock.withLock { statements.contains { $0.lowercased().contains("highlight(") } }
    }
    func append(_ statement: String) { lock.withLock { statements.append(statement) } }
}
