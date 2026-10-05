import Foundation
import Testing

@testable import CapdAnswers

private actor Retriever: AnswerRetrieving {
    let hits: [AnswerEvidence]
    var calls = 0
    var limits: [Int] = []
    var queries: [String] = []
    init(
        _ hits: [AnswerEvidence] = [
            .init(id: "capture-a", title: "Hiking", excerpt: "Pack water and a warm jacket.")
        ]
    ) {
        self.hits = hits
    }
    func search(_ queries: [String], limit: Int) async throws -> [[AnswerEvidence]] {
        calls += 1
        limits.append(limit)
        self.queries.append(contentsOf: queries)
        return queries.map { _ in hits }
    }
}

private actor Model: AnswerGenerating {
    nonisolated let status: AnswerAvailability
    let draft: AnswerDraft
    var sources: [NumberedEvidence] = []
    var calls = 0
    init(status: AnswerAvailability = .available, draft: AnswerDraft = supportedDraft) {
        self.status = status
        self.draft = draft
    }
    nonisolated func availability() -> AnswerAvailability { status }
    func answer(question: String, sources: [NumberedEvidence]) async throws -> AnswerDraft {
        calls += 1
        self.sources = sources
        return draft
    }
}

private let supportedDraft = AnswerDraft(statements: [
    .init(
        text: "Bring water and a warm layer.",
        citations: [.init(number: 1, quote: "Pack water and a warm jacket.")])
])

@Test func citationsComeFromRetrievedIDsAndExactQuotes() async throws {
    let model = Model(
        draft: .init(statements: [
            supportedDraft.statements[0],
            .init(text: "Invented source", citations: [.init(number: 99, quote: "Pack water")]),
            .init(
                text: "Invented quote", citations: [.init(number: 1, quote: "Wear purple shoes")]),
            .init(text: "No citation", citations: []),
            .init(
                text: "One bad citation spoils this statement",
                citations: [
                    .init(number: 1, quote: "Pack water"), .init(number: 9, quote: "Pack water"),
                ]),
        ]))
    let result = try await GroundedAnswerService(retriever: Retriever(), model: model).answer(
        "What to pack hiking?")
    #expect(result.statements == supportedDraft.statements)
    #expect(result.sources.map(\.source.id) == ["capture-a"])
}

@Test func refusesNoMatchesAndUncitedAnswerInsteadOfInventing() async throws {
    await #expect(throws: AnswerError.insufficientEvidence) {
        try await GroundedAnswerService(retriever: Retriever([]), model: Model()).answer("hiking")
    }
    await #expect(throws: AnswerError.insufficientEvidence) {
        try await GroundedAnswerService(
            retriever: Retriever(), model: Model(draft: .init(statements: []))
        ).answer("hiking")
    }
}

@Test func distinctQuotesFromSameSourceRemainInCitationOrder() async throws {
    let citations: [AnswerDraft.Citation] = [
        .init(number: 1, quote: "a warm jacket."),
        .init(number: 1, quote: "Pack water"),
        .init(number: 1, quote: "Pack\nwater"),
        .init(number: 2, quote: "Pack water"),
        .init(number: 1, quote: "a warm jacket."),
    ]
    let reader = Retriever([
        .init(id: "capture-a", title: "Hiking", excerpt: "Pack water and a warm jacket."),
        .init(id: "capture-b", title: "Water", excerpt: "Pack water for the trail."),
    ])
    let model = Model(
        draft: .init(statements: [.init(text: "Bring supplies.", citations: citations)]))
    let answer = try await GroundedAnswerService(retriever: reader, model: model).answer("hiking")
    #expect(answer.statements.first?.citations == [citations[0], citations[1], citations[3]])
    #expect(answer.sources.map(\.source.id) == ["capture-a", "capture-b"])
}

@Test func invalidLaterQuoteFromSameSourceRejectsEntireStatement() async throws {
    let model = Model(
        draft: .init(statements: [
            .init(
                text: "Bring supplies.",
                citations: [
                    .init(number: 1, quote: "Pack water"),
                    .init(number: 1, quote: "Wear purple shoes"),
                ])
        ]))
    await #expect(throws: AnswerError.insufficientEvidence) {
        try await GroundedAnswerService(retriever: Retriever(), model: model).answer("hiking")
    }
}

@Test(arguments: ["hiking", "What about hiking?", "Tell me about 猫"])
func singleTermQuestionRetrievesExactlyOnce(question: String) async throws {
    let reader = Retriever()
    let terms = GroundedAnswerService.searchTerms(question)
    #expect(terms.count == 1)
    _ = try await GroundedAnswerService(retriever: reader, model: Model()).answer(question)
    #expect(await reader.calls == 1)
    #expect(await reader.queries == terms)
}

private actor RankedRetriever: AnswerRetrieving {
    var queries: [String] = []
    func search(_ queries: [String], limit: Int) -> [[AnswerEvidence]] {
        self.queries = queries
        return queries.map { query in
            let id = query == "hiking water" ? "combined-only" : "both-terms"
            return [.init(id: id, title: id, excerpt: "Pack water and a warm jacket.")]
        }
    }
}

@Test func multiTermQueriesKeepCombinedSearchAndMatchCountRanking() async throws {
    let reader = RankedRetriever()
    let model = Model()
    _ = try await GroundedAnswerService(retriever: reader, model: model).answer(
        "What about hiking hiking water?")
    #expect(await reader.queries == ["hiking water", "hiking", "water"])
    #expect(await model.sources.map(\.source.id) == ["both-terms", "combined-only"])
}

@Test func unavailableModelDoesNotReadCaptures() async throws {
    for reason in [
        AnswerAvailability.Reason.deviceNotEligible, .intelligenceDisabled, .modelNotReady,
        .unsupportedLanguage, .requiresNewerOS, .unknown,
    ] {
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
    await #expect(throws: AnswerError.questionTooLong) {
        try await service.answer(String(repeating: "h", count: 501))
    }
    #expect(await reader.calls == 0)
}

@Test(arguments: [
    "hiking e" + String(repeating: "\u{301}", count: 1_200),
    String(repeating: " ", count: 2_001) + "hiking",
])
func oversizedEncodedQuestionsDoNotReachRetrievalOrGeneration(question: String) async throws {
    let reader = Retriever()
    let model = Model()
    #expect(question.trimmingCharacters(in: .whitespacesAndNewlines).count <= 500)
    await #expect(throws: AnswerError.questionTooLong) {
        try await GroundedAnswerService(retriever: reader, model: model).answer(question)
    }
    #expect(GroundedAnswerService.searchTerms(question).isEmpty)
    #expect(await reader.calls == 0)
    #expect(await model.calls == 0)
}

private actor RetrieverFactoryProbe {
    var calls = 0
    func open() -> Retriever {
        calls += 1
        return Retriever()
    }
}

@Test @MainActor func oversizedEncodedSessionQuestionDoesNotStartARequest() async {
    let factory = RetrieverFactoryProbe()
    let model = Model()
    let session = AnswerSession(model: model, retriever: { await factory.open() })
    session.question = "hiking e" + String(repeating: "\u{301}", count: 1_200)
    session.ask()
    #expect(!session.isAnswering)
    #expect(session.message == AnswerError.questionTooLong.localizedDescription)
    await Task.yield()
    #expect(await factory.calls == 0)
    #expect(await model.calls == 0)
    session.cancel()
}

@Test(arguments: [
    String(repeating: "猫", count: 500),
    "hiking e" + String(repeating: "\u{301}", count: 996),
])
func multibyteQuestionsWithinBothLimitsAreAccepted(question: String) async throws {
    let reader = Retriever()
    let model = Model()
    let answer = try await GroundedAnswerService(retriever: reader, model: model).answer(question)
    #expect(answer.question == question)
    #expect(await reader.calls == 1)
    #expect(await reader.queries.count <= 9)
    #expect(await model.calls == 1)
}

@Test func questionByteBoundaryIsIndependentOfCharacterCount() throws {
    let question = "hiking e" + String(repeating: "\u{301}", count: 996)
    #expect(question.utf8.count == 2_000)
    #expect(try GroundedAnswerService.validatedQuestion(question) == question)
    #expect(throws: AnswerError.questionTooLong) {
        try GroundedAnswerService.validatedQuestion(question + "a")
    }
    let emojiQuestion = String(repeating: "🐈", count: 500)
    #expect(try GroundedAnswerService.validatedQuestion(emojiQuestion) == emojiQuestion)
}

@Test(arguments: [
    "e" + String(repeating: "\u{301}", count: 1_200),
    "Hiking e" + String(repeating: "\u{301}", count: 1_200) + " trail",
    String(repeating: "猫", count: 160),
    String(repeating: "🐈", count: 160),
])
func sourceTitlesHaveIndependentUnicodeByteBounds(title: String) async throws {
    let reader = Retriever([
        .init(id: "capture-a", title: title, excerpt: "Pack water and a warm jacket.")
    ])
    let model = Model()
    let answer = try await GroundedAnswerService(retriever: reader, model: model).answer("hiking")
    let bounded = try #require(answer.sources.first?.source.title)
    #expect(bounded.utf8.count <= 640)
    #expect(bounded.count <= 160)
    #expect(title.unicodeScalars.starts(with: bounded.unicodeScalars))
    #expect(!bounded.unicodeScalars.contains { $0.value == 0xFFFD })
    #expect(await model.sources.first?.source.title == bounded)
    if title.utf8.count <= 640 { #expect(bounded == title) }
}

@Test func evidenceAndQueryFanoutStayBoundedAndDeduplicated() async throws {
    let hits = (0..<30).map {
        AnswerEvidence(
            id: "capture-\($0)", title: String(repeating: "T", count: 300),
            excerpt: String(repeating: "Pack water and a warm jacket. ", count: 400))
    }
    let reader = Retriever(hits + hits)
    let model = Model()
    _ = try await GroundedAnswerService(retriever: reader, model: model).answer(
        "hiking water jacket boots trail forest map compass rain tent")
    let sources = await model.sources
    #expect(sources.count <= GroundedAnswerService.sourceLimit)
    #expect(Set(sources.map(\.source.id)).count == sources.count)
    #expect(
        sources.allSatisfy {
            $0.source.excerpt.count <= GroundedAnswerService.excerptLimit
                && $0.source.title.count <= 160
        })
    #expect(
        sources.reduce(0) { $0 + $1.source.excerpt.count }
            <= GroundedAnswerService.totalExcerptLimit)
    #expect(await reader.calls == 1)
    #expect(await reader.limits.allSatisfy { $0 == 12 })
}

@Test func quotedWhitespaceIsNormalizedButWordsCannotChange() async throws {
    let model = Model(
        draft: .init(statements: [
            .init(
                text: "Bring layers.",
                citations: [
                    .init(number: 1, quote: "water\n and a warm jacket.")
                ])
        ]))
    let result = try await GroundedAnswerService(retriever: Retriever(), model: model).answer(
        "hiking")
    #expect(result.statements[0].citations[0].quote == "water and a warm jacket.")
}

@Test func oversizedGraphemeCannotBypassFinalExcerptByteBudget() async throws {
    let oversized = "e" + String(repeating: "\u{301}", count: 600)
    #expect(oversized.count == 1)
    #expect(oversized.utf8.count > GroundedAnswerService.excerptLimit)
    let reader = Retriever([
        .init(
            id: "capture-a", title: "Hiking",
            excerpt: "Pack water and a warm jacket. " + oversized)
    ])
    let model = Model()
    let answer = try await GroundedAnswerService(retriever: reader, model: model).answer("hiking")
    let excerpt = try #require(answer.sources.first?.source.excerpt)
    #expect(excerpt.utf8.count <= GroundedAnswerService.excerptLimit)
    #expect(!excerpt.unicodeScalars.contains { $0.value == 0x301 })
    #expect(await model.sources.first?.source.excerpt == excerpt)
}

@Test(arguments: [150, 200])
func mergedMultibyteExcerptsRespectPerSourceAndTotalByteBudgets(repetitions: Int) async throws {
    let reader = Retriever(
        (0..<6).map { index in
            .init(
                id: "capture-\(index)", title: "Hiking",
                excerpt: "Pack water and a warm jacket.\n\n"
                    + String(repeating: "猫", count: repetitions) + "\n\n"
                    + String(repeating: "犬", count: repetitions))
        })
    let model = Model()
    _ = try await GroundedAnswerService(retriever: reader, model: model).answer("hiking water")
    let sources = await model.sources
    #expect(!sources.isEmpty)
    #expect(
        sources.allSatisfy { $0.source.excerpt.utf8.count <= GroundedAnswerService.excerptLimit })
    #expect(
        sources.reduce(0) { $0 + $1.source.excerpt.utf8.count }
            <= GroundedAnswerService.totalExcerptLimit)
    #expect(sources.allSatisfy { !$0.source.excerpt.contains("\u{FFFD}") })
}

@Test func invalidStatementDoesNotSuppressLaterValidStatementWithSameText() async throws {
    let text = supportedDraft.statements[0].text
    let model = Model(
        draft: .init(statements: [
            .init(text: text, citations: [.init(number: 99, quote: "Invented quote")]),
            supportedDraft.statements[0],
        ]))
    let result = try await GroundedAnswerService(retriever: Retriever(), model: model).answer(
        "hiking")
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
    func finish() {
        continuation?.resume(returning: supportedDraft)
        continuation = nil
    }
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
    let session = AnswerSession(
        model: Model(status: .unavailable(.modelNotReady)),
        retriever: {
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
