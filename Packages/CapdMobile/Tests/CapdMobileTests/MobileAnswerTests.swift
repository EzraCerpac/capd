import CapdAnswers
import CapdSync
import Foundation
import Testing

@testable import CapdMobile

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
