import CapdAnswers
import CapdSync
import Foundation
import GRDB
import Testing
import os

@testable import CapdMobile

@Test func localAnswerFanoutKeepsOneSnapshotDuringConcurrentEdits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-snapshot-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let saved = MobileCapture(
        kind: .text, title: "Plant notes", selection: "Orchid water requirements before revision.")
    try mobile.save(saved)
    let writer = try DatabaseQueue(path: url.path)
    let queryCount = OSAllocatedUnfairLock(initialState: 0)
    var configuration = Configuration()
    configuration.readonly = true
    configuration.prepareDatabase { db in
        db.trace { event in
            guard case .statement(let statement) = event,
                statement.sql.hasPrefix("SELECT mobile_captures.id, mobile_captures.title")
            else { return }
            let shouldEdit = queryCount.withLock { count in
                count += 1
                return count == 2
            }
            guard shouldEdit else { return }
            do {
                try writer.write { db in
                    try db.execute(
                        sql: "UPDATE mobile_captures SET selection = ? WHERE id = ?",
                        arguments: [
                            "Orchid water requirements after revision.", saved.id.uuidString,
                        ])
                }
            } catch {
                Issue.record(error)
            }
        }
    }
    let pool = try DatabasePool(path: url.path, configuration: configuration)
    let reader = MobileAnswerRetrieval(database: pool)
    let queries = ["orchid water", "orchid", "water"]
    let results = try await reader.search(queries, limit: 12)
    #expect(queryCount.withLock { $0 } == queries.count)
    #expect(results.count == queries.count)
    #expect(results.allSatisfy { $0.first?.id == saved.id.uuidString })
    #expect(results.allSatisfy { $0.first?.excerpt == saved.selection })
    #expect(
        try mobile.capture(id: saved.id)?.selection == "Orchid water requirements after revision.")
    #expect(
        try await reader.search("water", limit: 12).first?.excerpt.contains("after revision")
            == true)
}

@Test func localAnswerRetrievalFindsSavedBodyAndPreservesOutbox() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-readonly-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let saved = MobileCapture(
        kind: .text, title: "Walking", selection: "Pack water and a warm jacket.")
    try mobile.save(saved)
    var remote = SharedCapture(
        source: CaptureSource(
            kind: .link,
            url: "https://example.invalid/synthetic", title: "Saved guide"))
    remote.generated.body =
        String(repeating: "Synthetic introduction. ", count: 200)
        + "An orchid needs bright indirect light, not direct midday sun."
    let server = try SyncServer(
        databaseURL: root.appendingPathComponent("server.sqlite"),
        blobDirectory: root.appendingPathComponent("server-blobs"))
    _ = try server.apply(
        SyncOperation(
            deviceID: UUID(), sequence: 1, captureID: remote.id, baseRevision: 0,
            mutation: .create(remote)))
    try mobile.pull(from: server)
    let before = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let result = try await reader.search("orchids", limit: 12)
    #expect(result.map(\.id) == [remote.id.uuidString])
    #expect(result[0].excerpt.contains("orchid needs bright indirect light"))
    #expect(result[0].excerpt.count <= GroundedAnswerService.excerptLimit)
    #expect(try await reader.search("water", limit: 1).map(\.id) == [saved.id.uuidString])
    #expect(try mobile.pending() == before)
    #expect(try mobile.capture(id: saved.id)?.selection == saved.selection)
    #expect(try mobile.capture(id: remote.id)?.body == remote.generated.body)
}

@Test func localAnswerRetrievalRanksRelevantOlderTextAheadOfRecentMatches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-rank-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let relevant = MobileCapture(
        kind: .text, title: "Plants",
        selection: "Orchid orchid orchid orchid. Water sparingly.")
    try mobile.save(relevant)
    for _ in 0..<16 {
        try mobile.save(
            MobileCapture(
                kind: .text, title: "Diary",
                selection: String(repeating: "An unrelated synthetic sentence. ", count: 100)
                    + "One orchid."))
    }
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    #expect(try await reader.search("orchids", limit: 1).map(\.id) == [relevant.id.uuidString])
}

@Test func localAnswerRetrievalDoesNotCreateMissingDatabase() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-no-answer-db-\(UUID()).sqlite")
    #expect(throws: (any Error).self) { try MobileAnswerRetrieval(databaseURL: url) }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func localAnswerRetrievalUsesSavedProseForTitleMatches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-title-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let mobile = try MobileStore(url: url)
    let title = "Paris is the capital of France"
    try mobile.save(
        MobileCapture(kind: .link, url: "https://example.invalid/title", title: title))
    let saved = MobileCapture(
        kind: .link, url: "https://example.invalid/prose", title: title,
        note: "The saved observation describes a river crossing.")
    try mobile.save(saved)
    let before = try mobile.pending()
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try await reader.search("Paris", limit: 12)
    #expect(evidence.map(\.id) == [saved.id.uuidString])
    #expect(evidence.first?.excerpt == saved.note)
    #expect(try mobile.pending() == before)
}

@Test(arguments: [1, 2, 5, 6])
func localAnswerRetrievalExcerptsOnlyMatchingSavedProse(column: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-column-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    _ = try MobileStore(url: url)
    let prose = "A kestrel … is a small falcon."
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
        var saved = MobileCapture(
            kind: .link, title: String(repeating: "Kestrel title metadata. ", count: 20))
        switch column {
        case 1: saved.selection = prose
        case 2: saved.note = prose
        case 5: saved.body = prose
        default: saved.ocrText = prose
        }
        try saved.insert(db)
    }
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    #expect(try await reader.search("kestrels", limit: 1).first?.excerpt == prose)
}

@Test func localAnswerRetrievalKeepsTruncatedQuotesVerbatim() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-verbatim-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    _ = try MobileStore(url: url)
    let prose = (0..<160).map { "word\($0)" }.joined(separator: " ")
    let database = try DatabaseQueue(path: url.path)
    try await database.write { db in
        var saved = MobileCapture(kind: .link, title: "Saved long passage")
        saved.body = prose
        try saved.insert(db)
    }
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let evidence = try #require(try await reader.search("word110", limit: 1).first)
    #expect(prose.contains(evidence.excerpt))
    #expect(!evidence.excerpt.contains("…"))
    let quote = evidence.excerpt.split(whereSeparator: \.isWhitespace)
        .filter { $0 != "…" }.prefix(2).joined(separator: " ")
    let answer = try await GroundedAnswerService(
        retriever: reader, model: QuotationModel(quote: quote)
    ).answer("word110")
    #expect(answer.statements.first?.citations.first?.quote == quote)
    await #expect(throws: AnswerError.insufficientEvidence) {
        try await GroundedAnswerService(
            retriever: reader, model: QuotationModel(quote: "… " + quote)
        ).answer("word110")
    }
}

private struct QuotationModel: AnswerGenerating {
    let quote: String
    func availability() -> AnswerAvailability { .available }
    func answer(question: String, sources: [NumberedEvidence]) async throws -> AnswerDraft {
        .init(statements: [
            .init(text: "A saved quotation.", citations: [.init(number: 1, quote: quote)])
        ])
    }
}
