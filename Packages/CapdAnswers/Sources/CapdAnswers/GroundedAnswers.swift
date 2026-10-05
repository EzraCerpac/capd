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

/// Reads local captures from one snapshot, returning one result list per query in order.
public protocol AnswerRetrieving: Sendable {
    func search(_ queries: [String], limit: Int) async throws -> [[AnswerEvidence]]
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
    /// Maximum UTF-8 bytes in a question before trimming or text processing.
    public static let questionByteLimit = 2_000
    /// Maximum UTF-8 bytes in one source title supplied to the model.
    public static let titleByteLimit = 640
    /// Maximum UTF-8 bytes in one source excerpt.
    public static let excerptLimit = 1_000
    /// Maximum UTF-8 bytes across the source excerpts supplied to the model.
    public static let totalExcerptLimit = 5_000
    private struct Passage {
        let text: String
        let weight: Double
        let isTruncated: Bool
    }
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
        let question = try Self.validatedQuestion(rawQuestion)
        if case .unavailable(let reason) = availability() { throw AnswerError.unavailable(reason) }
        let terms = Self.searchTerms(question)
        guard !terms.isEmpty else { throw AnswerError.insufficientEvidence }

        struct Candidate {
            let evidence: AnswerEvidence
            var excerpts: [Passage]
            var matches: Int
            var score: Double
        }
        var candidates: [String: Candidate] = [:]
        var queries = [(terms.joined(separator: " "), 8.0)]
        if terms.count > 1 { queries += terms.map { ($0, 2.0) } }
        let results = try await retriever.search(queries.map(\.0), limit: 12)
        for ((_, weight), hits) in zip(queries, results) {
            try Task.checkCancellation()
            var seen = Set<String>()
            for (rank, evidence) in hits.prefix(12).enumerated() {
                guard !evidence.id.isEmpty, seen.insert(evidence.id).inserted else { continue }
                let score = weight / Double(rank + 1)
                if var previous = candidates[evidence.id] {
                    previous.matches += 1
                    previous.score += score
                    for fragment in Self.passages(evidence.excerpt, weight: weight) {
                        if previous.excerpts.contains(where: {
                            $0.text.contains(fragment.text) && $0.weight >= weight
                        }) {
                            continue
                        }
                        previous.excerpts.removeAll {
                            fragment.text.contains($0.text) && weight >= $0.weight
                        }
                        previous.excerpts.append(fragment)
                    }
                    candidates[evidence.id] = previous
                } else {
                    candidates[evidence.id] = Candidate(
                        evidence: evidence,
                        excerpts: Self.passages(evidence.excerpt, weight: weight),
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
            remaining -= excerpt.utf8.count
            sources.append(
                .init(
                    number: sources.count + 1,
                    source: .init(
                        id: candidate.evidence.id,
                        title: Self.boundedTitle(candidate.evidence.title), excerpt: excerpt)))
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
            for citation in statement.citations {
                let quote = Self.normalized(citation.quote)
                // Reject the whole statement if any purported source or verbatim support
                // is invented. This verifies source membership and quotes, not entailment.
                guard let source = byNumber[citation.number], !quote.isEmpty, quote.count <= 240,
                    Self.fragments(source.excerpt).contains(where: {
                        $0.contains(quote) && (quote.count >= 8 || quote == $0)
                    })
                else { return nil }
                let validated = AnswerDraft.Citation(number: citation.number, quote: quote)
                if !citations.contains(validated) {
                    citations.append(validated)
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

    static func validatedQuestion(_ rawQuestion: String) throws -> String {
        guard rawQuestion.utf8.prefix(questionByteLimit + 1).count <= questionByteLimit else {
            throw AnswerError.questionTooLong
        }
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AnswerError.emptyQuestion }
        guard question.count <= 500 else { throw AnswerError.questionTooLong }
        return question
    }

    private static func boundedTitle(_ title: String) -> String {
        var bounded = ""
        var remaining = titleByteLimit
        // Scalar iteration bounds work even when one character spans the entire title.
        for scalar in title.unicodeScalars {
            let cost = scalar.utf8.count
            guard cost <= remaining else { break }
            bounded.unicodeScalars.append(scalar)
            remaining -= cost
        }
        return String(bounded.prefix(160))
    }

    public static func searchTerms(_ rawQuestion: String) -> [String] {
        guard let question = try? validatedQuestion(rawQuestion) else { return [] }
        let stop: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "by", "can", "did", "do",
            "does", "for", "from", "has", "have", "how", "i", "in", "is", "it", "me", "my", "of",
            "on", "or", "saved", "source", "sources", "that", "the", "these", "this", "to", "was",
            "were", "what", "when", "where", "which", "who", "why", "with", "about", "tell",
        ]
        var seen = Set<String>()
        let text = question.lowercased().replacingOccurrences(
            of: #"['’]s\b"#, with: "", options: .regularExpression)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var terms: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            for part in text[range].split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let term = String(part)
                if !stop.contains(term) && seen.insert(term).inserted {
                    terms.append(term)
                }
            }
            return true
        }
        guard terms.count > 8 else { return terms }
        return (0..<8).map { terms[$0 * (terms.count - 1) / 7] }
    }

    private static func fragments(_ excerpt: String) -> [String] {
        passages(excerpt, weight: 0).map(\.text)
    }

    private static func passages(_ excerpt: String, weight: Double) -> [Passage] {
        excerpt.components(separatedBy: "\n\n").compactMap {
            let fragment = normalized(boundedPrefix($0, byteLimit: excerptLimit))
            return fragment.isEmpty
                ? nil
                : Passage(text: fragment, weight: weight, isTruncated: $0.utf8.count > excerptLimit)
        }
    }

    private static func boundedPrefix(_ text: String, byteLimit: Int) -> String {
        var end = text.startIndex
        var remaining = byteLimit
        while end < text.endIndex {
            let next = text.index(after: end)
            let cost = text[end..<next].utf8.count
            guard cost <= remaining else { break }
            remaining -= cost
            end = next
        }
        return String(text[..<end])
    }

    private static func mergedExcerpts(_ fragments: [Passage], limit: Int) -> String {
        let separator = "\n\n"
        var remaining = limit
        var selected: [(offset: Int, element: Passage)] = []
        let prioritized = fragments.enumerated().sorted {
            if $0.element.weight != $1.element.weight {
                return $0.element.weight > $1.element.weight
            }
            if $0.element.text.utf8.count != $1.element.text.utf8.count {
                return $0.element.text.utf8.count < $1.element.text.utf8.count
            }
            return $0.offset < $1.offset
        }
        for (index, fragment) in prioritized.enumerated() {
            let cost =
                fragment.element.text.utf8.count + (selected.isEmpty ? 0 : separator.utf8.count)
            // A clipped prefix should not crowd out another complete matching passage.
            let reserve =
                selected.isEmpty && fragment.element.isTruncated
                ? (prioritized.dropFirst(index + 1).map { $0.element.text.utf8.count }.min().map {
                    $0 + separator.utf8.count
                } ?? 0) : 0
            guard cost + reserve <= remaining else { continue }
            selected.append(fragment)
            remaining -= cost
        }
        return selected.sorted { $0.offset < $1.offset }.map(\.element.text).joined(
            separator: separator)
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
