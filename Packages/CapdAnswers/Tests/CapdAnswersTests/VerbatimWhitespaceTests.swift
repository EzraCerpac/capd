import Testing

@testable import CapdAnswers

@Suite("Verbatim whitespace in retrieved evidence")
struct VerbatimWhitespaceTests {
    @Test(arguments: ["\n", "\t", "  "])
    func storedWhitespaceReachesModelAndReturnedCitation(separator: String) async throws {
        let quote = "New\(separator)York has museums."
        let reader = VerbatimRetriever(excerpt: " \t\(quote) \r\n")
        let model = VerbatimModel(quote: " \t\(quote) \r\n")
        let answer = try await GroundedAnswerService(retriever: reader, model: model).answer(
            "New York")
        #expect(await model.sources.first?.source.excerpt == quote)
        #expect(answer.sources.first?.source.excerpt == quote)
        #expect(answer.statements.first?.citations.first?.quote == quote)
    }

    @Test(arguments: ["\n", "\t", "  "])
    func collapsedWhitespaceQuoteIsRejected(separator: String) async throws {
        let reader = VerbatimRetriever(excerpt: "New\(separator)York has museums.")
        let model = VerbatimModel(quote: "New York has museums.")
        await #expect(throws: AnswerError.insufficientEvidence) {
            try await GroundedAnswerService(retriever: reader, model: model).answer("New York")
        }
    }

    @Test func mergedPassagesPreserveInternalWhitespaceAndCitationBoundaries() async throws {
        let first = "New\nYork has museums."
        let second = "Daily\tschedule has  two tours."
        let reader = VerbatimRetriever(excerpt: "\(first)\n\n\(second)")
        let answer = try await GroundedAnswerService(
            retriever: reader, model: VerbatimModel(quote: second)
        ).answer("New York tours")
        #expect(answer.sources.first?.source.excerpt == "\(first)\n\n\(second)")
        #expect(answer.statements.first?.citations.first?.quote == second)
        await #expect(throws: AnswerError.insufficientEvidence) {
            try await GroundedAnswerService(
                retriever: reader, model: VerbatimModel(quote: "museums.\n\nDaily\tschedule")
            ).answer("New York tours")
        }
    }
}

private struct VerbatimRetriever: AnswerRetrieving {
    let excerpt: String
    func evidenceRevision() -> String { "immutable" }
    func search(_ queries: [String], limit: Int) -> [[AnswerEvidence]] {
        queries.map { _ in [.init(id: "synthetic", title: "Places", excerpt: excerpt)] }
    }
}

private actor VerbatimModel: AnswerGenerating {
    let quote: String
    var sources: [NumberedEvidence] = []
    init(quote: String) { self.quote = quote }
    nonisolated func availability() -> AnswerAvailability { .available }
    func answer(question: String, sources: [NumberedEvidence]) -> AnswerDraft {
        self.sources = sources
        return .init(statements: [
            .init(text: "Synthetic statement", citations: [.init(number: 1, quote: quote)])
        ])
    }
}
