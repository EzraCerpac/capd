import Foundation
import GRDB
import Synchronization
import Testing

@testable import CapdKit

@Suite("Library answers")
struct LibraryAnswerServiceTests {
    @Test("A natural-language question retrieves topic words and returns cited claims")
    func answersFromRetrievedCaptures() async throws {
        try await withAnswerStore { store in
            let targetID = try insert(
                Capture(
                    kind: .link,
                    url: "https://example.com/swift-cancellation",
                    host: "example.com",
                    title: "Swift concurrency cancellation",
                    body: "Cancellation is cooperative. Tasks check for cancellation explicitly.",
                    createdAt: Date(timeIntervalSince1970: 2)),
                into: store)
            _ = try insert(
                Capture(
                    kind: .link,
                    url: "https://example.com/other",
                    host: "example.com",
                    title: "Concurrency elsewhere",
                    body: "A general overview of concurrent systems.",
                    createdAt: Date(timeIntervalSince1970: 1)),
                into: store)

            let observed = Mutex<[LibraryAnswerPromptSource]>([])
            let model = StubAnswerModel { _, sources in
                observed.withLock { $0 = sources }
                return LibraryAnswerDraft(
                    statements: [
                        .init(
                            text: "Swift task cancellation is cooperative.",
                            sourceNumbers: [1])
                    ])
            }
            let service = LibraryAnswerService(
                search: SearchService(store: store), model: model)

            let answer = try await service.answer(
                "What did I save about Swift concurrency cancellation?")

            #expect(
                answer.passages == [
                    .init(text: "Swift task cancellation is cooperative.", citations: [1])
                ])
            #expect(answer.sources.first?.captureID == targetID)
            #expect(answer.sources.first?.number == 1)
            #expect(observed.withLock { $0.first?.excerpt.contains("cooperative") } == true)
        }
    }

    @Test("Invalid citations and unsupported statements never reach the answer")
    func sanitizesClaims() async throws {
        try await withAnswerStore { store in
            _ = try insert(
                Capture(
                    kind: .text,
                    title: "Subscription notes",
                    selection: "Subscriptions can make long-term costs hard to predict.",
                    createdAt: Date()),
                into: store)
            let model = StubAnswerModel { _, _ in
                LibraryAnswerDraft(
                    statements: [
                        .init(text: " Costs are less predictable. ", sourceNumbers: [1, 99, 1]),
                        .init(text: "Costs are less predictable.", sourceNumbers: [1]),
                        .init(text: "An unsupported addition.", sourceNumbers: [99]),
                    ])
            }
            let service = LibraryAnswerService(
                search: SearchService(store: store), model: model)

            let answer = try await service.answer("arguments against subscriptions")

            #expect(
                answer.passages == [
                    .init(text: "Costs are less predictable.", citations: [1])
                ])
        }
    }

    @Test(
        "Sources changed during awaited generation require a new answer",
        arguments: [
            "edit", "delete", "title", "url", "host", "note", "body", "ocr", "kind", "revision",
            "unchanged",
        ])
    func revalidatesSources(change: String) async throws {
        try await withAnswerStore { store in
            let id = try insert(
                Capture(
                    kind: .text, title: "Hiking", selection: "Pack water and a warm jacket.",
                    createdAt: Date()),
                into: store)
            _ = try insert(
                Capture(
                    kind: .text, title: "Hiking backup", selection: "Carry a map while hiking.",
                    createdAt: Date(timeIntervalSince1970: 1)),
                into: store)
            let model = StubAnswerModel { _, sources in
                #expect(sources.count == 2)
                await Task.yield()
                try await store.dbPool.write { db in
                    switch change {
                    case "edit":
                        try db.execute(
                            sql: "UPDATE captures SET selection = ? WHERE id = ?",
                            arguments: ["Changed while answering", id])
                    case "delete":
                        try db.execute(sql: "DELETE FROM captures WHERE id = ?", arguments: [id])
                    case "title", "url", "host", "note", "body":
                        try db.execute(
                            sql: "UPDATE captures SET \(change) = ? WHERE id = ?",
                            arguments: ["Changed while answering", id])
                    case "ocr":
                        try db.execute(
                            sql: "UPDATE captures SET ocr_text = ? WHERE id = ?",
                            arguments: ["Changed while answering", id])
                    case "kind":
                        try db.execute(
                            sql: "UPDATE captures SET kind = 'link' WHERE id = ?", arguments: [id])
                    case "revision":
                        try db.execute(
                            sql: "UPDATE captures SET updated_at = ? WHERE id = ?",
                            arguments: [Date(timeIntervalSince1970: 1), id])
                    default: break
                    }
                }
                return LibraryAnswerDraft(statements: [
                    .init(text: "Bring water, a warm layer, and a map.", sourceNumbers: [1, 2])
                ])
            }
            let service = LibraryAnswerService(search: SearchService(store: store), model: model)
            if change == "unchanged" || change == "revision" || change == "kind" {
                let answer = try await service.answer("hiking")
                #expect(answer.sources.map(\.captureID).contains(id))
                #expect(answer.sources.count == 2)
            } else {
                await #expect(throws: LibraryAnswerError.evidenceChanged) {
                    try await service.answer("hiking")
                }
            }
        }
    }

    @Test(arguments: ["bodySuffix", "unusedOCR", "omittedSnippet", "bodyPrefix"])
    func validatesOnlyBoundedPromptEvidence(change: String) async throws {
        try await withAnswerStore { store in
            let prefix =
                "Hiking requires water. " + String(repeating: "Saved context. ", count: 180)
            var capture = Capture(
                kind: .text, title: "Hiking", body: prefix + "Original suffix.",
                ocrText: "Unused OCR text.", createdAt: Date())
            if change == "omittedSnippet" {
                capture.title = "Gear notes"
                capture.selection = String(repeating: "Saved context. ", count: 180)
                capture.tags = "hiking"
            }
            let id = try insert(capture, into: store)
            let observed = Mutex("")
            let model = StubAnswerModel { _, sources in
                let excerpt = sources[0].excerpt
                observed.withLock { $0 = excerpt }
                #expect(excerpt.count == LibraryAnswerService.excerptLimit)
                #expect(!excerpt.contains("Original suffix"))
                #expect(!excerpt.contains("Unused OCR"))
                if change == "omittedSnippet" {
                    #expect(!excerpt.contains("Relevant excerpt:"))
                }
                await Task.yield()
                try await store.dbPool.write { db in
                    switch change {
                    case "bodySuffix":
                        try db.execute(
                            sql: "UPDATE captures SET body = ? WHERE id = ?",
                            arguments: [prefix + "Changed suffix.", id])
                    case "unusedOCR":
                        try db.execute(
                            sql:
                                "UPDATE captures SET ocr_text = 'Changed unused OCR.' WHERE id = ?",
                            arguments: [id])
                    case "omittedSnippet":
                        try db.execute(
                            sql: "UPDATE captures SET tags = 'cycling' WHERE id = ?",
                            arguments: [id])
                    default:
                        try db.execute(
                            sql:
                                "UPDATE captures SET body = 'Changed visible content.' WHERE id = ?",
                            arguments: [id])
                    }
                }
                return LibraryAnswerDraft(statements: [
                    .init(text: "Saved context is available.", sourceNumbers: [1])
                ])
            }
            let service = LibraryAnswerService(search: SearchService(store: store), model: model)
            if change == "bodyPrefix" {
                await #expect(throws: LibraryAnswerError.evidenceChanged) {
                    try await service.answer("hiking")
                }
            } else {
                let answer = try await service.answer("hiking")
                #expect(answer.sources.first?.captureID == id)
                #expect(answer.sources.first?.excerpt == observed.withLock { $0 })
            }
        }
    }

    @Test(arguments: ["combining", "zwj", "emoji", "separator"])
    func boundedProjectionPreservesNormalizedGraphemes(shape: String) async throws {
        try await withAnswerStore { store in
            let start: String
            switch shape {
            case "combining": start = "  \u{301}text\n\t"
            case "zwj": start = "\u{200D}👩‍👩‍👧‍👦 text\n\t"
            case "emoji": start = "🇺🇸👩‍🚀 text\n\t"
            default: start = "text "
            }
            _ = try insert(
                Capture(
                    kind: .text, title: "Hiking",
                    selection: start
                        + String(repeating: "water ", count: 400), createdAt: Date()), into: store)
            let search = SearchService(store: store)
            let retrieval = LibraryAnswerService(
                search: search, model: StubAnswerModel { _, _ in .init(statements: []) })
            let hit = try #require(retrieval.retrieve("hiking").first)
            let reference = [
                "Title: Hiking", "Selected text: " + (hit.capture.selection ?? ""),
                "Relevant excerpt: " + (hit.snippet?.text ?? ""),
            ].joined(separator: "\n").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let expected = String(reference.prefix(LibraryAnswerService.excerptLimit))
            let model = StubAnswerModel { _, sources in
                #expect(sources[0].excerpt == expected)
                #expect(sources[0].excerpt.count <= LibraryAnswerService.excerptLimit)
                return .init(statements: [.init(text: "Bring water.", sourceNumbers: [1])])
            }
            _ = try await LibraryAnswerService(search: search, model: model).answer("hiking")
        }
    }

    @Test(arguments: ["word", "label", "space"])
    func croppedSnippetUsesOnlyIncludedEvidence(boundary: String) async throws {
        try await withAnswerStore { store in
            let prefix = "Title: Gear notes Selected text: "
            let retained =
                boundary == "label"
                ? " Relevant ex"
                : " Relevant excerpt: " + (boundary == "word" ? "hiki" : "hiking ")
            var capture = Capture(
                kind: .text, title: "Gear notes",
                selection: String(
                    repeating: "x",
                    count: LibraryAnswerService.excerptLimit
                        - prefix.count - retained.count), createdAt: Date())
            capture.tags = "hiking backpack"
            let id = try insert(capture, into: store)
            let model = StubAnswerModel { _, sources in
                #expect(sources[0].excerpt.hasSuffix(retained))
                #expect(sources[0].excerpt.count == LibraryAnswerService.excerptLimit)
                try await store.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE captures SET tags = ? WHERE id = ?",
                        arguments: [boundary == "label" ? "cycling" : "hiking outdoors", id])
                }
                return .init(statements: [.init(text: "Saved gear notes.", sourceNumbers: [1])])
            }
            _ = try await LibraryAnswerService(
                search: SearchService(store: store), model: model
            ).answer("hiking")
        }
    }

    @Test func tagSnippetAllowsUnrelatedTagAddition() async throws {
        try await withAnswerStore { store in
            var capture = Capture(kind: .text, title: "Gear notes", createdAt: Date())
            capture.tags = "hiking"
            let id = try insert(capture, into: store)
            let model = StubAnswerModel { _, sources in
                #expect(sources[0].excerpt.contains("Relevant excerpt: hiking"))
                try await store.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE captures SET tags = 'outdoors hiking' WHERE id = ?",
                        arguments: [id])
                }
                return .init(statements: [.init(text: "Hiking is saved here.", sourceNumbers: [1])])
            }
            _ = try await LibraryAnswerService(
                search: SearchService(store: store), model: model
            ).answer("hiking")
        }
    }

    @Test(arguments: ["tagging", "claim", "timestamps", "rating"])
    func bookkeepingChangesKeepUnchangedEvidence(change: String) async throws {
        try await withAnswerStore { store in
            let id = try insert(
                Capture(
                    kind: .text, title: "Hiking", selection: "Pack water and a warm jacket.",
                    createdAt: Date()), into: store)
            let model = StubAnswerModel { _, sources in
                #expect(sources.first?.excerpt.contains("Pack water") == true)
                await Task.yield()
                try await store.dbPool.write { db in
                    switch change {
                    case "tagging":
                        try db.execute(
                            sql:
                                "UPDATE captures SET tags = 'outdoors', tags_version = 2 WHERE id = ?",
                            arguments: [id])
                    case "claim":
                        try db.execute(
                            sql:
                                "UPDATE captures SET enrichment_state = 'fetching', attempt_count = 1, last_attempt_at = ?, body_status = 'thin', body_source = 'fetch' WHERE id = ?",
                            arguments: [Date(), id])
                    case "timestamps":
                        try db.execute(
                            sql:
                                "UPDATE captures SET updated_at = ?, last_seen_at = ?, seen_count = 2, reminder_at = ? WHERE id = ?",
                            arguments: [Date(), Date(), Date(), id])
                    default:
                        try db.execute(
                            sql: "UPDATE captures SET rating = 5 WHERE id = ?", arguments: [id])
                    }
                }
                return LibraryAnswerDraft(statements: [
                    .init(text: "Bring water and a warm layer.", sourceNumbers: [1])
                ])
            }
            let answer = try await LibraryAnswerService(
                search: SearchService(store: store), model: model
            ).answer("hiking")
            #expect(answer.sources.first?.captureID == id)
            #expect(answer.sources.first?.excerpt.contains("Pack water") == true)
        }
    }

    @Test(arguments: [false, true])
    func tagSnippetEvidenceStaysFencedUnlessProseSupportsIt(prose: Bool) async throws {
        try await withAnswerStore { store in
            var capture = Capture(kind: .text, title: "Gear notes", createdAt: Date())
            capture.tags = prose ? "outdoors" : "hiking"
            if prose {
                capture.body =
                    String(repeating: "Earlier context. ", count: 70)
                    + "Hiking\nrequires\twater and a warm jacket. "
                    + String(repeating: "Later context. ", count: 70)
            }
            let id = try insert(capture, into: store)
            let observed = Mutex("")
            let model = StubAnswerModel { _, sources in
                observed.withLock { $0 = sources[0].excerpt }
                #expect(sources.first?.excerpt.lowercased().contains("hiking") == true)
                if prose { #expect(sources.first?.excerpt.contains("…") == true) }
                await Task.yield()
                try await store.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE captures SET tags = 'cycling' WHERE id = ?", arguments: [id])
                }
                return LibraryAnswerDraft(statements: [
                    .init(text: "Hiking is saved here.", sourceNumbers: [1])
                ])
            }
            let service = LibraryAnswerService(search: SearchService(store: store), model: model)
            if prose {
                let answer = try await service.answer("hiking")
                #expect(answer.sources.first?.excerpt == observed.withLock { $0 })
            } else {
                await #expect(throws: LibraryAnswerError.evidenceChanged) {
                    try await service.answer("hiking")
                }
            }
        }
    }

    @Test func hostSnippetAllowsUnrelatedTagChanges() async throws {
        try await withAnswerStore { store in
            var capture = Capture(
                kind: .link, url: "https://hiking.example.invalid/item",
                host: "hiking.example.invalid", title: "Gear notes", createdAt: Date())
            capture.tags = "outdoors"
            let id = try insert(capture, into: store)
            let model = StubAnswerModel { _, sources in
                #expect(sources[0].excerpt.contains("Relevant excerpt: hiking.example.invalid"))
                await Task.yield()
                try await store.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE captures SET tags = 'cycling' WHERE id = ?", arguments: [id])
                }
                return LibraryAnswerDraft(statements: [
                    .init(text: "A saved hiking site.", sourceNumbers: [1])
                ])
            }
            let answer = try await LibraryAnswerService(
                search: SearchService(store: store), model: model
            ).answer("hiking")
            #expect(answer.sources.first?.captureID == id)
        }
    }

    @Test("A canceled model completion never publishes an answer")
    func canceledGeneration() async throws {
        try await withAnswerStore { store in
            _ = try insert(
                Capture(
                    kind: .text, title: "Hiking", selection: "Pack water and a warm jacket.",
                    createdAt: Date()),
                into: store)
            let model = StubAnswerModel { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return LibraryAnswerDraft(statements: [
                    .init(text: "Bring water.", sourceNumbers: [1])
                ])
            }
            let service = LibraryAnswerService(search: SearchService(store: store), model: model)
            let task = Task { try await service.answer("hiking") }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    @Test("A question mark prefix is syntax, not part of retrieval")
    func questionPrefix() {
        #expect(
            LibraryAnswerService.normalizedQuestion(" ?  local-first software ")
                == "local-first software")
        #expect(
            LibraryAnswerService.significantTerms(
                in: "What was that article about local-first software?")
                == ["article", "local-first", "software"])
    }

    @Test("Availability is checked before retrieval or generation")
    func unavailableModel() async throws {
        try await withAnswerStore { store in
            let model = StubAnswerModel(availability: .unavailable(.appleIntelligenceOff)) {
                _, _ in
                Issue.record("The unavailable model should not be called")
                return LibraryAnswerDraft(statements: [])
            }
            let service = LibraryAnswerService(
                search: SearchService(store: store), model: model)

            await #expect(throws: LibraryAnswerError.unavailable(.appleIntelligenceOff)) {
                try await service.answer("swift")
            }
        }
    }

    @Test("No matching captures produces a useful failure")
    func noMatches() async throws {
        try await withAnswerStore { store in
            let service = LibraryAnswerService(
                search: SearchService(store: store),
                model: StubAnswerModel { _, _ in
                    LibraryAnswerDraft(statements: [])
                })

            await #expect(throws: LibraryAnswerError.noMatches) {
                try await service.answer("a topic that is absent")
            }
        }
    }
}

private struct StubAnswerModel: LibraryAnswerModel {
    let state: LibraryAnswerAvailability
    let response:
        @Sendable (String, [LibraryAnswerPromptSource]) async throws
            -> LibraryAnswerDraft

    init(
        availability: LibraryAnswerAvailability = .available,
        response:
            @escaping @Sendable (String, [LibraryAnswerPromptSource]) async throws
            -> LibraryAnswerDraft
    ) {
        state = availability
        self.response = response
    }

    func availability() -> LibraryAnswerAvailability { state }

    func answer(
        question: String,
        sources: [LibraryAnswerPromptSource]
    ) async throws -> LibraryAnswerDraft {
        try await response(question, sources)
    }
}

private func withAnswerStore(_ body: (Store) async throws -> Void) async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("capd-answer-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(try Store(paths: StoragePaths(root: root)))
}

@discardableResult
private func insert(_ capture: Capture, into store: Store) throws -> Int64 {
    try store.dbPool.write { db in
        var capture = capture
        try capture.insert(db)
        return try #require(capture.id)
    }
}
