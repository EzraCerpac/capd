import CapdAnswers
import CapdSync
import Foundation
import GRDB
import Testing
import os

@testable import CapdMobile

@Suite("Answer evidence projection revision")
struct MobileAnswerEvidenceRevisionTests {
    @Test(arguments: ["create", "edit", "rejected"])
    func acknowledgementBookkeepingKeepsGeneratedAnswer(action: String) async throws {
        let fixture = EvidenceRevisionFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        let server = try fixture.server()
        let saved = MobileCapture(
            kind: .text, title: "Hiking", selection: "Pack water and a warm jacket.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(saved)
        if action != "create" {
            try store.push(to: server)
            try store.pull(from: server)
            if action == "edit" {
                try store.update(id: saved.id, note: "Prepared note", tags: [])
            } else {
                let discarded = try CaptureInput.make(text: "Discarded source", isLink: false)
                try store.save(discarded)
                try store.push(to: server)
                try store.delete(id: discarded.id)
                try store.push(to: server)
                try store.delete(id: discarded.id)
            }
        }
        let reader = try MobileAnswerRetrieval(databaseURL: fixture.url)
        let evidence = try await reader.search("hiking", limit: 12)
        let before = try await reader.evidenceRevision()
        let bookkeeping = try store.libraryRevision()
        let model = EvidenceRevisionModel()
        let task = Task {
            try await GroundedAnswerService(retriever: reader, model: model).answer("hiking")
        }
        await model.waitUntilStarted()
        let receipt = try #require(store.push(to: server).first)
        #expect(receipt.outcome == (action == "rejected" ? .deleted : .accepted))
        #expect(try store.pending().isEmpty)
        #expect(try store.libraryRevision() != bookkeeping)
        #expect(try store.rejectedWork().count == (action == "rejected" ? 1 : 0))
        #expect(try await reader.search("hiking", limit: 12) == evidence)
        #expect(try await reader.evidenceRevision() == before)
        await model.finish()
        let answer = try await task.value
        #expect(answer.sources.first?.source.id == saved.id.uuidString)
    }

    @Test(arguments: [
        "title", "selection", "note", "body", "ocrText", "id", "localID", "createdAt", "manualTags",
        "generatedTags", "delete", "rollback", "metadata",
    ])
    func actualProjectionChangesFenceAnswerWhileRolledBackAndNonEvidenceWritesDoNot(
        field: String
    ) async throws {
        let fixture = EvidenceRevisionFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        let saved = MobileCapture(
            kind: .text, title: "Hiking", selection: "Pack water and a warm jacket.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(saved)
        let reader = try MobileAnswerRetrieval(databaseURL: fixture.url)
        let before = try await reader.evidenceRevision()
        let model = EvidenceRevisionModel()
        let task = Task {
            try await GroundedAnswerService(retriever: reader, model: model).answer("hiking")
        }
        await model.waitUntilStarted()
        let writer = try DatabaseQueue(path: fixture.url.path)
        if field == "rollback" {
            do {
                try await writer.write { db in
                    try db.execute(sql: "UPDATE mobile_captures SET note='Rolled back note'")
                    throw EvidenceFixtureError.rollback
                }
            } catch EvidenceFixtureError.rollback {}
        } else if field == "delete" {
            try store.delete(id: saved.id)
        } else {
            let sql: String
            switch field {
            case "title": sql = "UPDATE mobile_captures SET title='Walking'"
            case "selection":
                sql = "UPDATE mobile_captures SET selection='Pack juice and a warm jacket.'"
            case "note": sql = "UPDATE mobile_captures SET note='New saved note'"
            case "body": sql = "UPDATE mobile_captures SET body='New saved body'"
            case "ocrText": sql = "UPDATE mobile_captures SET ocrText='New saved OCR'"
            case "id": sql = "UPDATE mobile_captures SET id='00000000-0000-0000-0000-000000000001'"
            case "localID": sql = "UPDATE mobile_captures SET localID=localID+100"
            case "createdAt": sql = "UPDATE mobile_captures SET createdAt='2025-01-01 00:00:00.000'"
            case "manualTags": sql = "UPDATE mobile_captures SET manualTags='[\"manual\"]'"
            case "generatedTags": sql = "UPDATE mobile_captures SET generatedTags='[\"generated\"]'"
            default:
                sql =
                    """
                    UPDATE mobile_captures SET revision=revision+1, seenCount=seenCount+1,
                        noteConflicts='[{"operationID":"00000000-0000-0000-0000-000000000001","value":"Competing note"}]'
                    """
            }
            try await writer.write { try $0.execute(sql: sql) }
        }
        let changed = field != "rollback" && field != "metadata"
        #expect(try await reader.evidenceRevision() == before ? !changed : changed)
        await model.finish()
        if changed {
            await #expect(throws: AnswerError.evidenceChanged) { try await task.value }
        } else {
            #expect(try await task.value.sources.first?.source.id == saved.id.uuidString)
        }
    }

    @Test func legacyProjectionFailsClosedUntilWriterUpgradeWithoutChangingEvidenceOrOutbox()
        async throws
    {
        let fixture = EvidenceRevisionFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        let saved = MobileCapture(
            kind: .text, title: "Hiking", selection: "Pack water and a warm jacket.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(saved)
        let pending = try store.pending()
        let original = try store.capture(id: saved.id)
        let database = try DatabaseQueue(path: fixture.url.path)
        try await database.write { db in
            for event in ["insert", "delete", "update"] {
                try db.execute(sql: "DROP TRIGGER mobile_answer_evidence_\(event)")
            }
            try db.drop(table: "mobile_answer_evidence")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier='mobile-answer-evidence-v5'")
        }
        let legacy = try await database.read { db in
            try String.fetchAll(
                db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        let reader = try MobileAnswerRetrieval(databaseURL: fixture.url)
        let model = EvidenceRevisionModel()
        await #expect(throws: MobileAnswerRetrievalError.libraryUpgradeRequired) {
            try await GroundedAnswerService(retriever: reader, model: model).answer("hiking")
        }
        #expect(await model.callCount == 0)
        #expect(try store.pending() == pending)
        #expect(try store.capture(id: saved.id) == original)
        #expect(
            try await database.read { db in
                try String.fetchAll(
                    db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
                    == legacy && !db.tableExists("mobile_answer_evidence")
            })
        let upgraded = try MobileStore(url: fixture.url)
        #expect(upgraded.deviceID == store.deviceID)
        #expect(try upgraded.capture(id: saved.id) == original)
        #expect(try upgraded.pending() == pending)
        let token = try await reader.evidenceRevision()
        #expect(token.count == 32)
        #expect(try await reader.search("hiking", limit: 12).first?.id == saved.id.uuidString)
        #expect(
            try await database.read {
                try Int.fetchOne(
                    $0,
                    sql:
                        "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='mobile-answer-evidence-v5'"
                )
            } == 1)
    }

    @Test func evidenceRevisionReadsOnlyConstantSizeTokenWithLargeSavedProse() async throws {
        let fixture = EvidenceRevisionFixture()
        defer { fixture.clean() }
        let store = try MobileStore(url: fixture.url)
        try store.save(MobileCapture(kind: .text, title: "Hiking", selection: "Saved prose"))
        let writer = try DatabaseQueue(path: fixture.url.path)
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE mobile_captures SET body=?",
                arguments: [String(repeating: "Large saved body. ", count: 100_000)])
        }
        let statements = OSAllocatedUnfairLock(initialState: [String]())
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            db.trace { event in
                guard case .statement(let statement) = event else { return }
                let sql = statement.sql
                statements.withLock { $0.append(sql) }
            }
        }
        let database = try DatabasePool(path: fixture.url.path, configuration: configuration)
        let reader = MobileAnswerRetrieval(database: database)
        let token = try await reader.evidenceRevision()
        #expect(token.count == 32)
        let selects = statements.withLock { $0.filter { $0.hasPrefix("SELECT") } }
        #expect(selects.contains("SELECT revision FROM mobile_answer_evidence WHERE id=1"))
        #expect(
            selects.allSatisfy {
                !$0.contains("FROM mobile_captures") && !$0.contains("FROM sync_")
            })
    }
}

private enum EvidenceFixtureError: Error { case rollback }

private struct EvidenceRevisionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-answer-revision-\(UUID())")
    var url: URL { root.appendingPathComponent("mobile.sqlite") }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func server() throws -> SyncServer {
        try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-assets"))
    }
}

private actor EvidenceRevisionModel: AnswerGenerating {
    private var continuation: CheckedContinuation<AnswerDraft, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0
    nonisolated func availability() -> AnswerAvailability { .available }
    func answer(question: String, sources: [NumberedEvidence]) async throws -> AnswerDraft {
        callCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish() {
        continuation?.resume(
            returning: .init(statements: [
                .init(
                    text: "Bring water and a warm layer.",
                    citations: [.init(number: 1, quote: "Pack water and a warm jacket.")])
            ]))
        continuation = nil
    }
}
