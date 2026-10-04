import Foundation
import Testing

@testable import CapdAnswers

@Suite("Synthetic segmented questions and merged source passages")
struct RetrievalLanguageAndMergeTests {
    @Test(arguments: ["What is C?", "Tell me about R", "what is c?", "What is S?"])
    func singleCharacterTopicsReachRetrieval(question: String) async throws {
        let identifier = question.last { $0.isLetter }
        let term = String(try #require(identifier)).lowercased()
        let quote = "\(term.uppercased()) is a programming language."
        #expect(GroundedAnswerService.searchTerms(question) == [term])
        let reader = QueryPassageRetriever(passages: [term: quote])
        let answer = try await GroundedAnswerService(
            retriever: reader, model: PassageQuoteModel(quote: quote)
        ).answer(question)
        #expect(await reader.queries.contains(term))
        #expect(answer.statements.first?.citations.first?.quote == quote)
    }

    @Test(arguments: ["猫は哺乳類", "猫", "C"])
    func completeShortFragmentsCanBeQuoted(quote: String) async throws {
        let reader = QueryPassageRetriever(passages: ["topic": quote])
        let answer = try await GroundedAnswerService(
            retriever: reader, model: PassageQuoteModel(quote: quote)
        ).answer("topic")
        #expect(answer.statements.first?.citations.first?.quote == quote)
    }

    @Test(arguments: ["猫", "", "猫は"])
    func shortPartialOrEmptyQuotesRemainInvalid(quote: String) async throws {
        let reader = QueryPassageRetriever(passages: ["topic": "猫は哺乳類"])
        await #expect(throws: AnswerError.insufficientEvidence) {
            try await GroundedAnswerService(
                retriever: reader, model: PassageQuoteModel(quote: quote)
            ).answer("topic")
        }
    }

    @Test func mergedBudgetKeepsCompleteMatchingPassages() async throws {
        let terms = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
        let fragments = terms.map { term in
            String(repeating: "x", count: 150) + " \(term) fact. "
                + String(repeating: "y", count: 150)
        }
        let reader = QueryPassageRetriever(
            passages: Dictionary(uniqueKeysWithValues: zip(terms, fragments)))
        let quote = "eta fact."
        let model = PassageQuoteModel(quote: quote)
        let answer = try await GroundedAnswerService(retriever: reader, model: model).answer(
            terms.joined(separator: " "))
        let excerpt = try #require(answer.sources.first?.source.excerpt)
        let retained = excerpt.components(separatedBy: "\n\n")
        #expect(retained.count > 1)
        #expect(retained.count < fragments.count)
        #expect(retained.allSatisfy { fragments.contains($0) })
        #expect(excerpt.contains(quote))
        #expect(excerpt.count <= GroundedAnswerService.excerptLimit)
    }

    @Test(arguments: ["蘭に必要な光は何ですか", "兰花需要什么光照"])
    func nonSpaceQuestionsAreSegmented(question: String) {
        let terms = GroundedAnswerService.searchTerms(question)
        #expect(terms.count > 1)
        #expect(terms.count <= 8)
        #expect(!terms.contains(question))
        if question.contains("蘭") {
            #expect(terms.contains("蘭"))
            #expect(terms.contains("光"))
        } else {
            #expect(terms.contains("兰花"))
            #expect(terms.contains("光照"))
        }
        #expect(
            GroundedAnswerService.searchTerms("What about Orchid's watering?") == [
                "orchid", "watering",
            ])
    }

    @Test func segmentedJapaneseQuestionUsesLocalEvidence() async throws {
        let quote = "蘭には間接光が必要です"
        let reader = QueryPassageRetriever(passages: ["蘭": quote])
        let result = try await GroundedAnswerService(
            retriever: reader, model: PassageQuoteModel(quote: quote)
        ).answer("蘭に必要な光は何ですか")
        #expect(result.sources.first?.source.excerpt == quote)
        #expect(result.statements.first?.citations.first?.quote == quote)
        #expect(await reader.queries.contains("蘭"))
    }

    @Test func laterQueriesRetainDifferentPassagesFromSameSource() async throws {
        let selection = "orchid overview."
        let watering = "water orchids weekly."
        let reader = QueryPassageRetriever(passages: [
            "water orchid": selection, "water": watering, "orchid": selection,
        ])
        let result = try await GroundedAnswerService(
            retriever: reader, model: PassageQuoteModel(quote: watering)
        ).answer("water orchid")
        let excerpt = try #require(result.sources.first?.source.excerpt)
        #expect(excerpt.contains(selection))
        #expect(excerpt.contains(watering))
        #expect(excerpt.contains("\n\n"))
        #expect(result.sources.count == 1)
        #expect(excerpt.count <= GroundedAnswerService.excerptLimit)
    }

    @Test func longEarlierPassageCannotConsumeLaterFieldBudget() async throws {
        let selection = String(repeating: "orchid overview. ", count: 100)
        let watering = "water orchids weekly."
        let reader = QueryPassageRetriever(passages: [
            "water orchid": selection, "water": watering, "orchid": selection,
        ])
        let result = try await GroundedAnswerService(
            retriever: reader, model: PassageQuoteModel(quote: watering)
        ).answer("water orchid")
        let excerpt = try #require(result.sources.first?.source.excerpt)
        #expect(excerpt.contains(watering))
        #expect(excerpt.count <= GroundedAnswerService.excerptLimit)
    }

    @Test(arguments: [false, true])
    func citationsCannotBridgeDistinctFieldOrQueryPassages(separateQueries: Bool) async throws {
        let selection = "orchid overview."
        let watering = "water orchids weekly."
        let passages =
            separateQueries
            ? ["water orchid": selection, "water": watering, "orchid": selection]
            : ["water orchid": "\(selection)\n\n\(watering)"]
        let reader = QueryPassageRetriever(passages: passages)
        await #expect(throws: AnswerError.insufficientEvidence) {
            try await GroundedAnswerService(
                retriever: reader, model: PassageQuoteModel(quote: "overview. water orchids")
            ).answer("water orchid")
        }
        let valid = try await GroundedAnswerService(
            retriever: reader, model: PassageQuoteModel(quote: watering)
        ).answer("water orchid")
        #expect(valid.statements.first?.citations.first?.quote == watering)
        #expect(valid.sources.first?.source.excerpt == "\(selection)\n\n\(watering)")
    }
}

private actor QueryPassageRetriever: AnswerRetrieving {
    let passages: [String: String]
    var queries: [String] = []
    init(passages: [String: String]) { self.passages = passages }
    func search(_ queries: [String], limit: Int) -> [[AnswerEvidence]] {
        self.queries.append(contentsOf: queries)
        return queries.map { query in
            guard let excerpt = passages[query] else { return [] }
            return [
                AnswerEvidence(
                    id: "same-synthetic-source", title: "Synthetic source", excerpt: excerpt)
            ]
        }
    }
}

private struct PassageQuoteModel: AnswerGenerating {
    let quote: String
    func availability() -> AnswerAvailability { .available }
    func answer(question: String, sources: [NumberedEvidence]) async throws -> AnswerDraft {
        AnswerDraft(statements: [
            .init(
                text: "Synthetic supported statement", citations: [.init(number: 1, quote: quote)])
        ])
    }
}
