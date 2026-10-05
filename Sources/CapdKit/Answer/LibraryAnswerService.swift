import Foundation
import FoundationModels

public enum LibraryAnswerAvailability: Sendable, Equatable {
    case available
    case unavailable(Reason)

    public enum Reason: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceOff
        case modelDownloading
        case unknown

        public var explanation: String {
            switch self {
            case .deviceNotEligible:
                "This Mac cannot run Apple Intelligence."
            case .appleIntelligenceOff:
                "Apple Intelligence is turned off in System Settings."
            case .modelDownloading:
                "The Apple Intelligence model is still downloading."
            case .unknown:
                "Apple Intelligence is unavailable."
            }
        }
    }
}

public enum LibraryAnswerError: Error, LocalizedError, Equatable {
    case unavailable(LibraryAnswerAvailability.Reason)
    case emptyQuestion
    case noMatches
    case noSupportedClaims
    case contentRejected
    case evidenceChanged

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            reason.explanation
        case .emptyQuestion:
            "Type a question first."
        case .noMatches:
            "No captures matched that question. Try using a specific topic, title, or site."
        case .noSupportedClaims:
            "Cap couldn't build an answer supported by the matching captures."
        case .contentRejected:
            "Apple Intelligence couldn't answer from this content."
        case .evidenceChanged:
            "Saved sources changed while answering. Ask again."
        }
    }
}

public struct LibraryAnswer: Codable, Sendable, Equatable {
    public let question: String
    public let passages: [Passage]
    public let sources: [Source]

    public init(question: String, passages: [Passage], sources: [Source]) {
        self.question = question
        self.passages = passages
        self.sources = sources
    }

    public struct Passage: Codable, Sendable, Equatable, Identifiable {
        public let text: String
        /// One-based source numbers, matching ``LibraryAnswer/sources``.
        public let citations: [Int]

        public var id: String { "\(text)|\(citations)" }

        public init(text: String, citations: [Int]) {
            self.text = text
            self.citations = citations
        }
    }

    public struct Source: Codable, Sendable, Equatable, Identifiable {
        public let number: Int
        public let captureID: Int64
        public let kind: CaptureKind
        public let title: String
        public let url: String?
        public let host: String?
        /// The bounded evidence handed to the model, useful to MCP clients for verification.
        public let excerpt: String

        public var id: Int { number }

        public init(
            number: Int,
            captureID: Int64,
            kind: CaptureKind,
            title: String,
            url: String?,
            host: String?,
            excerpt: String
        ) {
            self.number = number
            self.captureID = captureID
            self.kind = kind
            self.title = title
            self.url = url
            self.host = host
            self.excerpt = excerpt
        }
    }
}

struct LibraryAnswerPromptSource: Sendable, Equatable {
    let number: Int
    let title: String
    let location: String
    let excerpt: String
}

struct LibraryAnswerDraft: Sendable, Equatable {
    let statements: [Statement]

    struct Statement: Sendable, Equatable {
        let text: String
        let sourceNumbers: [Int]
    }
}

protocol LibraryAnswerModel: Sendable {
    func availability() -> LibraryAnswerAvailability
    func answer(
        question: String,
        sources: [LibraryAnswerPromptSource]
    ) async throws -> LibraryAnswerDraft
}

private struct LibraryAnswerEvidenceSnapshot {
    let captureID: Int64
    let prompt: LibraryAnswerPromptSource
    let snippet: Snippet?
    let limit: Int
}

private struct LibraryAnswerEvidence {
    let excerpt: String
    let includedSnippet: String?
    let partialSnippetEnd: Bool
}

/// Retrieves a small, relevant evidence set before asking Apple's on-device model to
/// synthesize it. Retrieval and generation both stay on the Mac.
public struct LibraryAnswerService: Sendable {
    static let sourceLimit = 6
    static let perSearchLimit = 12
    static let excerptLimit = 1_600
    static let totalExcerptLimit = 8_000

    private let search: SearchService
    private let model: any LibraryAnswerModel

    public init(search: SearchService) {
        self.init(search: search, model: FoundationLibraryAnswerModel())
    }

    init(search: SearchService, model: any LibraryAnswerModel) {
        self.search = search
        self.model = model
    }

    public func availability() -> LibraryAnswerAvailability {
        model.availability()
    }

    public func answer(_ rawQuestion: String) async throws -> LibraryAnswer {
        let question = Self.normalizedQuestion(rawQuestion)
        guard !question.isEmpty else { throw LibraryAnswerError.emptyQuestion }
        if case .unavailable(let reason) = model.availability() {
            throw LibraryAnswerError.unavailable(reason)
        }

        let hits = try retrieve(question)
        guard !hits.isEmpty else { throw LibraryAnswerError.noMatches }

        var remaining = Self.totalExcerptLimit
        var sources: [LibraryAnswer.Source] = []
        var prompts: [LibraryAnswerPromptSource] = []
        var evidence: [LibraryAnswerEvidenceSnapshot] = []
        for hit in hits {
            guard let captureID = hit.capture.id, remaining > 0 else { continue }
            let limit = min(Self.excerptLimit, remaining)
            let excerpt = Self.evidence(
                from: hit.capture, snippet: hit.snippet, limit: limit
            ).excerpt
            guard !excerpt.isEmpty else { continue }
            remaining -= excerpt.count

            let number = sources.count + 1
            let title = Self.title(for: hit.capture)
            let location = hit.capture.url ?? hit.capture.host ?? "Capture #\(captureID)"
            sources.append(
                .init(
                    number: number,
                    captureID: captureID,
                    kind: hit.capture.kind,
                    title: title,
                    url: hit.capture.url,
                    host: hit.capture.host,
                    excerpt: excerpt))
            let prompt = LibraryAnswerPromptSource(
                number: number, title: title, location: location, excerpt: excerpt)
            prompts.append(prompt)
            evidence.append(
                .init(captureID: captureID, prompt: prompt, snippet: hit.snippet, limit: limit))
        }
        guard !sources.isEmpty else { throw LibraryAnswerError.noMatches }

        let draft = try await model.answer(question: question, sources: prompts)
        try Task.checkCancellation()
        let validNumbers = Set(sources.map(\.number))
        var seenStatements = Set<String>()
        let passages = draft.statements.compactMap { statement -> LibraryAnswer.Passage? in
            let text = statement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let citations = statement.sourceNumbers.reduce(into: [Int]()) { result, number in
                guard validNumbers.contains(number), !result.contains(number) else { return }
                result.append(number)
            }
            guard
                !text.isEmpty,
                !citations.isEmpty,
                seenStatements.insert(text.lowercased()).inserted
            else { return nil }
            return .init(text: text, citations: citations)
        }
        guard !passages.isEmpty else { throw LibraryAnswerError.noSupportedClaims }

        try Task.checkCancellation()
        let current = try search.captures(ids: sources.map(\.captureID))
        try Task.checkCancellation()
        guard current.count == evidence.count else { throw LibraryAnswerError.evidenceChanged }
        var validatedSources: [LibraryAnswer.Source] = []
        for snapshot in evidence {
            guard let capture = current.first(where: { $0.id == snapshot.captureID }) else {
                throw LibraryAnswerError.evidenceChanged
            }
            let projected = Self.evidence(
                from: capture, snippet: snapshot.snippet, limit: snapshot.limit)
            let prompt = LibraryAnswerPromptSource(
                number: snapshot.prompt.number, title: Self.title(for: capture),
                location: capture.url ?? capture.host ?? "Capture #\(snapshot.captureID)",
                excerpt: projected.excerpt)
            guard prompt == snapshot.prompt,
                Self.snippetSupported(
                    projected.includedSnippet, by: capture,
                    partialEnd: projected.partialSnippetEnd)
            else { throw LibraryAnswerError.evidenceChanged }
            validatedSources.append(
                .init(
                    number: prompt.number, captureID: snapshot.captureID, kind: capture.kind,
                    title: prompt.title, url: capture.url, host: capture.host,
                    excerpt: prompt.excerpt))
        }
        try Task.checkCancellation()
        return LibraryAnswer(question: question, passages: passages, sources: validatedSources)
    }

    /// Natural-language questions contain connective words that make an all-token FTS query
    /// too strict. A combined topic query supplies precision; single-term legs recover recall.
    func retrieve(_ question: String) throws -> [SearchHit] {
        let terms = Self.significantTerms(in: question)
        guard !terms.isEmpty else { return [] }

        struct Candidate {
            var hit: SearchHit
            var score: Double
            var matchedQueries: Int
        }
        var candidates: [Int64: Candidate] = [:]

        func merge(_ hits: [SearchHit], weight: Double) {
            for (rank, hit) in hits.enumerated() {
                guard let id = hit.capture.id else { continue }
                let rankScore = weight / Double(rank + 1)
                if var candidate = candidates[id] {
                    candidate.score += rankScore
                    candidate.matchedQueries += 1
                    candidates[id] = candidate
                } else {
                    candidates[id] = Candidate(hit: hit, score: rankScore, matchedQueries: 1)
                }
            }
        }

        merge(
            try search.search(terms.joined(separator: " "), limit: Self.perSearchLimit),
            weight: 8)
        for term in terms.prefix(8) {
            merge(try search.search(term, limit: Self.perSearchLimit), weight: 2)
        }

        return candidates.values.sorted { lhs, rhs in
            if lhs.matchedQueries != rhs.matchedQueries {
                return lhs.matchedQueries > rhs.matchedQueries
            }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return (lhs.hit.capture.createdAt, lhs.hit.capture.id ?? 0)
                > (rhs.hit.capture.createdAt, rhs.hit.capture.id ?? 0)
        }.prefix(Self.sourceLimit).map(\.hit)
    }

    public static func normalizedQuestion(_ raw: String) -> String {
        var question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.first == "?" {
            question.removeFirst()
            question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return question
    }

    static func significantTerms(in question: String) -> [String] {
        let words = question.lowercased().split { character in
            !character.isLetter && !character.isNumber && character != "-"
        }
        var seen = Set<String>()
        return words.compactMap { raw in
            let word = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard word.count > 1, !stopWords.contains(word), seen.insert(word).inserted else {
                return nil
            }
            return word
        }
    }

    private static let stopWords: Set<String> = [
        "about", "all", "also", "an", "and", "are", "as", "at", "be", "but", "by",
        "can", "compare", "did", "do", "does", "everything", "for", "from", "had",
        "has", "have", "how", "i", "in", "into", "is", "it", "me", "my", "of", "on",
        "or", "saved", "show", "source", "sources", "that", "the", "their", "them",
        "there", "these", "this", "to", "was", "were", "what", "when", "where", "which",
        "who", "why", "with",
    ]

    private static func snippetSupported(
        _ snippet: String?, by capture: Capture, partialEnd: Bool
    ) -> Bool {
        guard let snippet, !snippet.isEmpty else { return true }
        let fragments = snippet.split(separator: "…").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !fragments.isEmpty else { return true }
        return [
            capture.title, capture.host, capture.note, capture.selection, capture.body,
            capture.ocrText, capture.tags,
        ].compactMap { $0 }.contains { field in
            var start = field.startIndex
            for (index, fragment) in fragments.enumerated() {
                let words = fragment.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let first = words.first else { continue }
                var found = false
                while let range = field.range(of: first, range: start..<field.endIndex) {
                    start = range.upperBound
                    var end = range.upperBound
                    let before =
                        range.lowerBound > field.startIndex
                        ? field[field.index(before: range.lowerBound)] : nil
                    if first.first.map({ $0.isLetter || $0.isNumber }) == true,
                        before.map({ $0.isLetter || $0.isNumber }) == true
                    {
                        continue
                    }
                    var matches = true
                    for word in words.dropFirst() {
                        let separator = end
                        while end < field.endIndex, field[end].isWhitespace {
                            field.formIndex(after: &end)
                        }
                        guard end > separator, field[end...].hasPrefix(word) else {
                            matches = false
                            break
                        }
                        end = field.index(end, offsetBy: word.count)
                    }
                    guard matches else { continue }
                    let after = end < field.endIndex ? field[end] : nil
                    let allowsPartialEnd = partialEnd && index == fragments.count - 1
                    if !allowsPartialEnd,
                        fragment.last.map({ $0.isLetter || $0.isNumber }) == true,
                        after.map({ $0.isLetter || $0.isNumber }) == true
                    {
                        continue
                    }
                    start = end
                    found = true
                    break
                }
                guard found else { return false }
            }
            return true
        }
    }

    private static func evidence(
        from capture: Capture, snippet: Snippet?, limit: Int
    ) -> LibraryAnswerEvidence {
        var excerpt = ""
        var count = 0
        var pendingSpace = false
        var pendingCharacter = ""
        var pendingSnippet = false
        var includedSnippet: String?
        var partialSnippetEnd = false

        func emit(_ character: Character, isSnippet: Bool, next: Character?) {
            guard count < limit else { return }
            if character.isWhitespace {
                pendingSpace = true
                return
            }
            if pendingSpace, count > 0 {
                excerpt.append(" ")
                count += 1
                if count == limit { return }
                if isSnippet, includedSnippet?.isEmpty == false { includedSnippet?.append(" ") }
            }
            pendingSpace = false
            excerpt.append(character)
            count += 1
            if isSnippet {
                if includedSnippet == nil { includedSnippet = "" }
                includedSnippet?.append(character)
                partialSnippetEnd =
                    count == limit
                    && next.map { !$0.isWhitespace && $0 != "…" } == true
            }
        }

        func append(_ text: String, isSnippet: Bool = false) {
            for character in text {
                guard count < limit else { return }
                if pendingCharacter.isEmpty {
                    pendingCharacter = String(character)
                    pendingSnippet = isSnippet
                    continue
                }
                let combined = pendingCharacter + String(character)
                if combined.count == 1 {
                    pendingCharacter = combined
                    pendingSnippet = pendingSnippet || isSnippet
                } else {
                    let first = combined.first!
                    let last = combined.last!
                    emit(first, isSnippet: pendingSnippet, next: last)
                    pendingCharacter = String(last)
                    pendingSnippet = isSnippet
                }
            }
        }

        func part(_ label: String, _ text: String?, isSnippet: Bool = false) {
            guard count < limit, let text, !text.isEmpty else { return }
            if !excerpt.isEmpty || !pendingCharacter.isEmpty { append("\n") }
            append(label + ": ")
            append(text, isSnippet: isSnippet)
        }

        part("Title", capture.title)
        part("URL", capture.url)
        part("Note", capture.note)
        part("Selected text", capture.selection)
        part("Relevant excerpt", snippet?.text, isSnippet: true)
        part("Content", capture.body ?? capture.ocrText)
        if let character = pendingCharacter.first {
            emit(character, isSnippet: pendingSnippet, next: nil)
        }
        return .init(
            excerpt: excerpt, includedSnippet: includedSnippet, partialSnippetEnd: partialSnippetEnd
        )
    }

    private static func title(for capture: Capture) -> String {
        if let title = capture.title, !title.isEmpty { return title }
        if let host = capture.host, !host.isEmpty { return host }
        if let url = capture.url, !url.isEmpty { return url }
        switch capture.kind {
        case .link: return "Link"
        case .text: return "Text capture"
        case .image: return "Image capture"
        }
    }
}

/// Apple's system model implementation. A fresh session keeps each question inside the
/// small on-device context window and avoids carrying one library query into the next.
struct FoundationLibraryAnswerModel: LibraryAnswerModel {
    func availability() -> LibraryAnswerAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            .available
        case .unavailable(.deviceNotEligible):
            .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled):
            .unavailable(.appleIntelligenceOff)
        case .unavailable(.modelNotReady):
            .unavailable(.modelDownloading)
        case .unavailable:
            .unavailable(.unknown)
        }
    }

    func answer(
        question: String,
        sources: [LibraryAnswerPromptSource]
    ) async throws -> LibraryAnswerDraft {
        let session = LanguageModelSession(
            instructions: """
                Answer questions using only the numbered sources supplied by a private \
                capture library. Every statement must be directly supported by at least \
                one source. Cite the source numbers that support each statement. Never use \
                outside knowledge, invent a source, or claim more than the excerpts show. \
                If sources disagree, describe the disagreement. Do not repeat a statement. \
                Be concise and direct.
                """)
        let sourceText = sources.map { source in
            """
            [\(source.number)] \(source.title)
            Location: \(source.location)
            \(source.excerpt)
            """
        }.joined(separator: "\n\n")

        do {
            let response = try await session.respond(
                to: Prompt("Question: \(question)\n\nSources:\n\(sourceText)"),
                generating: GeneratedLibraryAnswer.self)
            return LibraryAnswerDraft(
                statements: response.content.statements.map {
                    .init(text: $0.text, sourceNumbers: $0.sourceNumbers)
                })
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                throw LibraryAnswerError.contentRejected
            case .assetsUnavailable:
                throw LibraryAnswerError.unavailable(.unknown)
            case .exceededContextWindowSize:
                throw LibraryAnswerError.noSupportedClaims
            default:
                throw error
            }
        }
    }
}

@Generable
private struct GeneratedLibraryAnswer {
    @Guide(description: "Concise supported statements, in the best order to answer the question")
    var statements: [GeneratedLibraryStatement]
}

@Generable
private struct GeneratedLibraryStatement {
    @Guide(description: "One or two sentences containing a claim supported by the cited sources")
    var text: String
    @Guide(description: "The one-based numbers of every supplied source supporting this statement")
    var sourceNumbers: [Int]
}
