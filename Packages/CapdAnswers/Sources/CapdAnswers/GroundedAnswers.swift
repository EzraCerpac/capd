import Foundation
import NaturalLanguage

public enum AnswerAvailability: Sendable, Equatable {
    case available
    case unavailable(Reason)

    public enum Reason: Sendable, Equatable {
        case requiresNewerOS, deviceNotEligible, intelligenceDisabled, modelNotReady
        case unsupportedLanguage, unknown

        public var explanation: String {
            switch self {
            case .requiresNewerOS: "Questions need iOS 26 or macOS 26 or later."
            case .deviceNotEligible: "This device cannot run Apple Intelligence."
            case .intelligenceDisabled: "Turn on Apple Intelligence in Settings, then try again."
            case .modelNotReady:
                "The on-device model is not ready. It may still be downloading. Connect to Wi-Fi and power, then try again later."
            case .unsupportedLanguage: "The on-device model does not support the current language."
            case .unknown: "The on-device model is unavailable. Try again later."
            }
        }
    }
}

public enum AnswerError: Error, LocalizedError, Equatable {
    case unavailable(AnswerAvailability.Reason)
    case emptyQuestion, questionTooLong
    case insufficientEvidence, contextTooLarge, contentRejected, generationFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason.explanation
        case .emptyQuestion: "Type a question first."
        case .questionTooLong: "Keep the question to 500 characters or fewer."
        case .insufficientEvidence:
            "There is not enough matching saved text to answer. Try a specific topic, title, or phrase."
        case .contextTooLarge:
            "The matching text is too large for this question. Try a narrower question."
        case .contentRejected: "Apple Intelligence could not answer from this content."
        case .generationFailed: "The on-device model could not finish. Try again."
        }
    }
}

/// App-owned evidence. IDs are opaque so Mac row IDs and mobile UUIDs can share the API.
public struct AnswerEvidence: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let excerpt: String

    public init(id: String, title: String, excerpt: String) {
        self.id = id
        self.title = title
        self.excerpt = excerpt
    }
}

/// Implementations must only read local captures and honor the candidate limit.
public protocol AnswerRetrieving: Sendable {
    func search(_ query: String, limit: Int) async throws -> [AnswerEvidence]
}

public struct NumberedEvidence: Sendable, Equatable {
    public let number: Int
    public let source: AnswerEvidence
    public init(number: Int, source: AnswerEvidence) {
        self.number = number
        self.source = source
    }
}

public struct AnswerDraft: Sendable, Equatable {
    public let statements: [Statement]
    public init(statements: [Statement]) { self.statements = statements }

    public struct Statement: Sendable, Equatable {
        public let text: String
        public let citations: [Citation]
        public init(text: String, citations: [Citation]) {
            self.text = text
            self.citations = citations
        }
    }

    public struct Citation: Sendable, Equatable {
        public let number: Int
        public let quote: String
        public init(number: Int, quote: String) {
            self.number = number
            self.quote = quote
        }
    }
}

public protocol AnswerGenerating: Sendable {
    func availability() -> AnswerAvailability
    func answer(question: String, sources: [NumberedEvidence]) async throws -> AnswerDraft
}

public struct GroundedAnswer: Sendable, Equatable {
    public let question: String
    public let statements: [AnswerDraft.Statement]
    public let sources: [NumberedEvidence]
}

/// Each question gets a fresh, bounded evidence set. No writes, sync, remote fallback,
/// transcript persistence, or logging are performed by this service.
public struct GroundedAnswerService: Sendable {
    public static let sourceLimit = 6
    public static let excerptLimit = 1_000
    public static let totalExcerptLimit = 5_000
    private let retriever: any AnswerRetrieving
    private let model: any AnswerGenerating

    public init(
        retriever: any AnswerRetrieving, model: any AnswerGenerating = OnDeviceAnswerModel()
    ) {
        self.retriever = retriever
        self.model = model
    }

    public func availability() -> AnswerAvailability { model.availability() }

    public func answer(_ rawQuestion: String) async throws -> GroundedAnswer {
        try Task.checkCancellation()
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AnswerError.emptyQuestion }
        guard question.count <= 500 else { throw AnswerError.questionTooLong }
        if case .unavailable(let reason) = availability() { throw AnswerError.unavailable(reason) }
        let terms = Self.searchTerms(question)
        guard !terms.isEmpty else { throw AnswerError.insufficientEvidence }

        struct Candidate {
            let evidence: AnswerEvidence
            var excerpts: [String]
            var matches: Int
            var score: Double
        }
        var candidates: [String: Candidate] = [:]
        let queries = [(terms.joined(separator: " "), 8.0)] + terms.map { ($0, 2.0) }
        for (query, weight) in queries {
            try Task.checkCancellation()
            let hits = try await retriever.search(query, limit: 12)
            var seen = Set<String>()
            for (rank, evidence) in hits.prefix(12).enumerated() {
                guard !evidence.id.isEmpty, seen.insert(evidence.id).inserted else { continue }
                let score = weight / Double(rank + 1)
                if var previous = candidates[evidence.id] {
                    previous.matches += 1
                    previous.score += score
                    for fragment in Self.fragments(evidence.excerpt) {
                        if previous.excerpts.contains(where: { $0.contains(fragment) }) { continue }
                        previous.excerpts.removeAll { fragment.contains($0) }
                        previous.excerpts.append(fragment)
                    }
                    candidates[evidence.id] = previous
                } else {
                    candidates[evidence.id] = Candidate(
                        evidence: evidence, excerpts: Self.fragments(evidence.excerpt),
                        matches: 1, score: score)
                }
            }
        }
        let ranked = candidates.values.sorted {
            if $0.matches != $1.matches { return $0.matches > $1.matches }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.evidence.id < $1.evidence.id
        }
        var remaining = Self.totalExcerptLimit
        var sources: [NumberedEvidence] = []
        for candidate in ranked {
            guard sources.count < Self.sourceLimit, remaining > 0 else { break }
            let excerpt = Self.mergedExcerpts(
                candidate.excerpts, limit: min(Self.excerptLimit, remaining))
            guard !excerpt.isEmpty else { continue }
            remaining -= excerpt.count
            sources.append(
                .init(
                    number: sources.count + 1,
                    source: .init(
                        id: candidate.evidence.id,
                        title: String(candidate.evidence.title.prefix(160)), excerpt: excerpt)))
        }
        guard !sources.isEmpty else { throw AnswerError.insufficientEvidence }
        try Task.checkCancellation()
        let draft = try await model.answer(question: question, sources: sources)
        try Task.checkCancellation()
        let byNumber = Dictionary(uniqueKeysWithValues: sources.map { ($0.number, $0.source) })
        var seenStatements = Set<String>()
        let statements = draft.statements.prefix(6).compactMap {
            statement -> AnswerDraft.Statement? in
            let text = statement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 800, !statement.citations.isEmpty,
                statement.citations.count <= 6
            else { return nil }
            var citations: [AnswerDraft.Citation] = []
            var seenSources = Set<Int>()
            for citation in statement.citations {
                let quote = Self.normalized(citation.quote)
                // Reject the whole statement if any purported source or verbatim support
                // is invented. This verifies source membership and quotes, not entailment.
                guard let source = byNumber[citation.number], quote.count >= 8, quote.count <= 240,
                    Self.fragments(source.excerpt).contains(where: { $0.contains(quote) })
                else { return nil }
                if seenSources.insert(citation.number).inserted {
                    citations.append(.init(number: citation.number, quote: quote))
                }
            }
            guard seenStatements.insert(text.lowercased()).inserted else { return nil }
            return .init(text: text, citations: citations)
        }
        guard !statements.isEmpty else { throw AnswerError.insufficientEvidence }
        let cited = Set(statements.flatMap { $0.citations.map(\.number) })
        return GroundedAnswer(
            question: question, statements: statements,
            sources: sources.filter { cited.contains($0.number) })
    }

    public static func searchTerms(_ question: String) -> [String] {
        let stop: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "by", "can", "did", "do",
            "does", "for", "from", "has", "have", "how", "i", "in", "is", "it", "me", "my", "of",
            "on", "or", "saved", "source", "sources", "that", "the", "these", "this", "to", "was",
            "were", "what", "when", "where", "which", "who", "why", "with", "about",
        ]
        var seen = Set<String>()
        let text = question.lowercased()
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var terms: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            for part in text[range].split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let term = String(part)
                let hasNonASCIIletter = term.unicodeScalars.contains {
                    $0.value > 127 && $0.properties.isAlphabetic
                }
                if (term.count > 1 || hasNonASCIIletter) && !stop.contains(term)
                    && seen.insert(term).inserted
                {
                    terms.append(term)
                }
            }
            return terms.count < 8
        }
        return Array(terms.prefix(8))
    }

    private static func fragments(_ excerpt: String) -> [String] {
        excerpt.components(separatedBy: "\n\n").compactMap {
            let fragment = String(normalized($0).prefix(excerptLimit))
            return fragment.isEmpty ? nil : fragment
        }
    }

    private static func mergedExcerpts(_ fragments: [String], limit: Int) -> String {
        let separator = "\n\n"
        let fragments = Array(fragments.prefix((limit + separator.count) / (separator.count + 1)))
        guard !fragments.isEmpty else { return "" }
        var remaining = limit - separator.count * (fragments.count - 1)
        let parts = fragments.enumerated().map { index, fragment in
            let part = String(fragment.prefix(remaining / (fragments.count - index)))
            remaining -= part.count
            return part
        }
        return parts.joined(separator: separator)
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
