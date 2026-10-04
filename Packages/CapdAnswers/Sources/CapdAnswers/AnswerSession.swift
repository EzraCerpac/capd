import Foundation
import Observation

/// Owns one request at a time. Cancellation discards late results even if the
/// underlying model does not immediately stop computing. No history is saved.
@MainActor
@Observable
public final class AnswerSession {
    public var question = ""
    public private(set) var availability: AnswerAvailability
    public private(set) var answer: GroundedAnswer?
    public private(set) var message: String?
    public private(set) var isAnswering = false
    private let model: any AnswerGenerating
    private let makeRetriever: @Sendable () async throws -> any AnswerRetrieving
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    public init(model: any AnswerGenerating = OnDeviceAnswerModel(),
        retriever: @escaping @Sendable () async throws -> any AnswerRetrieving) {
        self.model = model
        makeRetriever = retriever
        availability = model.availability()
    }

    public func refreshAvailability() { availability = model.availability() }

    public func ask() {
        guard !isAnswering else { return }
        refreshAvailability()
        answer = nil
        message = nil
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { message = AnswerError.emptyQuestion.localizedDescription; return }
        guard question.count <= 500 else { message = AnswerError.questionTooLong.localizedDescription; return }
        if case .unavailable(let reason) = availability { message = reason.explanation; return }
        let id = UUID()
        requestID = id
        isAnswering = true
        let model = model
        let makeRetriever = makeRetriever
        task = Task { [weak self] in
            do {
                let retriever = try await makeRetriever()
                try Task.checkCancellation()
                let result = try await GroundedAnswerService(retriever: retriever, model: model).answer(question)
                guard !Task.isCancelled, self?.requestID == id else { return }
                self?.answer = result
            } catch {
                guard !Task.isCancelled, self?.requestID == id else { return }
                self?.message = (error as? AnswerError)?.localizedDescription
                    ?? "Could not read the saved library. Try again."
                self?.refreshAvailability()
            }
            guard self?.requestID == id else { return }
            self?.requestID = nil
            self?.isAnswering = false
            self?.task = nil
        }
    }

    public func cancel() {
        let wasAnswering = isAnswering
        requestID = nil
        task?.cancel()
        task = nil
        isAnswering = false
        if wasAnswering { message = "Question canceled." }
    }

    public func questionChanged() {
        cancel()
        answer = nil
        message = nil
    }

    isolated deinit { task?.cancel() }
}
