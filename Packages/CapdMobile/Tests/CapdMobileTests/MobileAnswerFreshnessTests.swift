import CapdAnswers
import CapdSync
import Foundation
import Testing

@testable import CapdMobile

@Test(arguments: ["edit", "delete", "revision", "unchanged"])
func localAnswerRevalidatesEvidenceAfterAwaitedGeneration(change: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("mobile.sqlite")
    let store = try MobileStore(url: url)
    let server = try SyncServer(
        databaseURL: root.appendingPathComponent("server.sqlite"),
        blobDirectory: root.appendingPathComponent("blobs"))
    let saved = MobileCapture(
        kind: .text, title: "Hiking", selection: "Pack water and a warm jacket.")
    try store.save(saved)
    try store.push(to: server)
    try store.pull(from: server)
    let original = try #require(try store.capture(id: saved.id))
    let reader = try MobileAnswerRetrieval(databaseURL: url)
    let model = FreshnessModel()
    let task = Task {
        try await GroundedAnswerService(retriever: reader, model: model).answer("hiking")
    }
    for _ in 0..<200 where !(await model.started) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await model.started)
    switch change {
    case "edit": try store.update(original, note: "Changed while answering", tags: [])
    case "delete": try store.delete(id: saved.id)
    case "revision":
        _ = try server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: saved.id,
                baseRevision: original.revision, mutation: .edit(CaptureEdit(rating: 1))))
        try store.pull(from: server)
        #expect(try store.capture(id: saved.id)?.selection == original.selection)
        #expect(try store.capture(id: saved.id)?.revision != original.revision)
    default: break
    }
    await model.finish()
    if change == "unchanged" || change == "revision" {
        let answer = try await task.value
        #expect(answer.sources.first?.source.id == saved.id.uuidString)
    } else {
        await #expect(throws: AnswerError.evidenceChanged) { try await task.value }
    }
}

@Test func localAnswerRevalidationRejectsRetiredLibrarySelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try MobileLibrarySession.open(root: root, role: .app)
    try session.store.save(
        MobileCapture(kind: .text, title: "Hiking", selection: "Pack water and a warm jacket."))
    let reader = try MobileAnswerRetrieval(
        databaseURL: session.configuration.databaseURL(in: root),
        access: MobileLibraryAccess(root: root, configuration: session.configuration))
    let model = FreshnessModel()
    let task = Task {
        try await GroundedAnswerService(retriever: reader, model: model).answer("hiking")
    }
    for _ in 0..<200 where !(await model.started) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await model.started)
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let enrollment = try SyncEnrollment(
        endpoint: URL(string: "https://sync.example.invalid/v1/sync")!, binding: binding,
        deviceID: UUID())
    try MobileLibraryAccess.publish(
        MobileLibraryConfiguration(generation: UUID(), enrollment: enrollment), in: root)
    await model.finish()
    await #expect(throws: MobileActivationError.sessionReplaced) { try await task.value }
}

private actor FreshnessModel: AnswerGenerating {
    private var continuation: CheckedContinuation<AnswerDraft, Never>?
    var started = false
    nonisolated func availability() -> AnswerAvailability { .available }
    func answer(question: String, sources: [NumberedEvidence]) async throws -> AnswerDraft {
        started = true
        return await withCheckedContinuation { continuation = $0 }
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
