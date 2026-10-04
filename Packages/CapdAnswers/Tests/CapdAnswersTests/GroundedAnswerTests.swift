import Foundation
import Testing
@testable import CapdAnswers

private actor Retriever: AnswerRetrieving {
    let hits: [AnswerEvidence]
    var calls = 0
    var limits: [Int] = []
    init(_ hits: [AnswerEvidence] = [.init(id: "capture-a", title: "Hiking", excerpt: "Pack water and a warm jacket.")]) {
        self.hits = hits
    }
    func search(_ query: String, limit: Int) async throws -> [AnswerEvidence] {
        calls += 1; limits.append(limit)
        return hits
    }
}

private actor Model: AnswerGenerating {
    nonisolated let status: AnswerAvailability
    let draft: AnswerDraft
    var sources: [NumberedEvidence] = []
    var calls = 0
    init(status: AnswerAvailability = .available, draft: AnswerDraft = supportedDraft) {
        self.status = status; self.draft = draft
    }
    nonisolated func availability() -> AnswerAvailability { status }
    func answer(question: String, sources: [NumberedEvidence]) async throws -> AnswerDraft {
        calls += 1; self.sources = sources
        return draft
    }
}

private let supportedDraft = AnswerDraft(statements: [.init(text: "Bring water and a warm layer.",
    citations: [.init(number: 1, quote: "Pack water and a warm jacket.")])])

@Test func citationsComeFromRetrievedIDsAndExactQuotes() async throws {
    let model = Model(draft: .init(statements: [
        supportedDraft.statements[0],
        .init(text: "Invented source", citations: [.init(number: 99, quote: "Pack water")]),
        .init(text: "Invented quote", citations: [.init(number: 1, quote: "Wear purple shoes")]),
        .init(text: "No citation", citations: []),
        .init(text: "One bad citation spoils this statement", citations: [
            .init(number: 1, quote: "Pack water"), .init(number: 9, quote: "Pack water")]),
    ]))
    let result = try await GroundedAnswerService(retriever: Retriever(), model: model).answer("What to pack hiking?")
    #expect(result.statements == supportedDraft.statements)
    #expect(result.sources.map(\.source.id) == ["capture-a"])
}

@Test func refusesNoMatchesAndUncitedAnswerInsteadOfInventing() async throws {
    await #expect(throws: AnswerError.insufficientEvidence) {
        try await GroundedAnswerService(retriever: Retriever([]), model: Model()).answer("hiking")
    }
    await #expect(throws: AnswerError.insufficientEvidence) {
        try await GroundedAnswerService(retriever: Retriever(), model: Model(draft: .init(statements: []))).answer("hiking")
    }
}

@Test func unavailableModelDoesNotReadCaptures() async throws {
    for reason in [AnswerAvailability.Reason.deviceNotEligible, .intelligenceDisabled, .modelNotReady,
        .unsupportedLanguage, .requiresNewerOS, .unknown] {
        let reader = Retriever()
        let model = Model(status: .unavailable(reason))
        await #expect(throws: AnswerError.unavailable(reason)) {
            try await GroundedAnswerService(retriever: reader, model: model).answer("hiking")
        }
        #expect(await reader.calls == 0)
        #expect(await model.calls == 0)
    }
}

@Test func emptyAndOversizedQuestionsDoNotReadCaptures() async throws {
    let reader = Retriever()
    let service = GroundedAnswerService(retriever: reader, model: Model())
    await #expect(throws: AnswerError.emptyQuestion) { try await service.answer("  \n") }
    await #expect(throws: AnswerError.questionTooLong) { try await service.answer(String(repeating: "h", count: 501)) }
    #expect(await reader.calls == 0)
}

@Test func evidenceAndQueryFanoutStayBoundedAndDeduplicated() async throws {
    let hits = (0..<30).map { AnswerEvidence(id: "capture-\($0)", title: String(repeating: "T", count: 300),
        excerpt: String(repeating: "Pack water and a warm jacket. ", count: 400)) }
    let reader = Retriever(hits + hits)
    let model = Model()
    _ = try await GroundedAnswerService(retriever: reader, model: model).answer("hiking water jacket boots trail forest map compass rain tent")
    let sources = await model.sources
    #expect(sources.count <= GroundedAnswerService.sourceLimit)
    #expect(Set(sources.map(\.source.id)).count == sources.count)
    #expect(sources.allSatisfy { $0.source.excerpt.count <= GroundedAnswerService.excerptLimit && $0.source.title.count <= 160 })
    #expect(sources.reduce(0) { $0 + $1.source.excerpt.count } <= GroundedAnswerService.totalExcerptLimit)
    #expect(await reader.calls <= 9)
    #expect(await reader.limits.allSatisfy { $0 == 12 })
}

@Test func quotedWhitespaceIsNormalizedButWordsCannotChange() async throws {
    let model = Model(draft: .init(statements: [.init(text: "Bring layers.", citations: [
        .init(number: 1, quote: "water\n and a warm jacket.")])]))
    let result = try await GroundedAnswerService(retriever: Retriever(), model: model).answer("hiking")
    #expect(result.statements[0].citations[0].quote == "water and a warm jacket.")
}

@Test func invalidStatementDoesNotSuppressLaterValidStatementWithSameText() async throws {
    let text = supportedDraft.statements[0].text
    let model = Model(draft: .init(statements: [
        .init(text: text, citations: [.init(number: 99, quote: "Invented quote")]),
        supportedDraft.statements[0],
    ]))
    let result = try await GroundedAnswerService(retriever: Retriever(), model: model).answer("hiking")
    #expect(result.statements == supportedDraft.statements)
}

private actor HeldModel: AnswerGenerating {
    private var continuation: CheckedContinuation<AnswerDraft, Never>?
    var started = false
    nonisolated func availability() -> AnswerAvailability { .available }
    func answer(question: String, sources: [NumberedEvidence]) async throws -> AnswerDraft {
        started = true
        // Deliberately ignores task cancellation, like a backend that completes late.
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: supportedDraft); continuation = nil }
}

@MainActor
@Test func canceledLateAnswerCannotReappearOrOverwriteNewQuestion() async throws {
    let model = HeldModel()
    let session = AnswerSession(model: model, retriever: { Retriever() })
    session.question = "What to pack hiking?"
    session.ask()
    for _ in 0..<100 where !(await model.started) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await model.started)
    session.cancel()
    session.question = "A different question"
    session.questionChanged()
    await model.finish()
    try await Task.sleep(for: .milliseconds(20))
    #expect(session.answer == nil)
    #expect(!session.isAnswering)
    #expect(session.message == nil)
}

@MainActor
@Test func unavailableSessionDoesNotOpenReaderAndCanRefresh() {
    let session = AnswerSession(model: Model(status: .unavailable(.modelNotReady)), retriever: {
        Issue.record("Unavailable session must not construct a reader")
        return Retriever()
    })
    session.question = "hiking"
    session.ask()
    #expect(!session.isAnswering)
    #expect(session.message == AnswerAvailability.Reason.modelNotReady.explanation)
    session.refreshAvailability()
    #expect(session.availability == .unavailable(.modelNotReady))
}
