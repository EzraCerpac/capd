import Darwin
import Foundation
import FoundationModels

// Explicit diagnostic only. All prompts and evidence are fixed synthetic text.
// This executable has no capture, database, sync, remote-model or credential input.
// Raw errors are safe here; do not copy this logging into production answering.

#if !SIMPLE_PROBE
@available(iOS 26, macOS 26, *)
@Generable
struct SyntheticFact {
    var light: String
}
#endif

#if !PROBE_APP
@main
#endif
@available(iOS 26.4, macOS 26.4, *)
struct ModelProbe {
    static func main() async {
        Task {
            try? await Task.sleep(for: .seconds(45))
            print("PROBE_TIMEOUT")
            fflush(stdout)
            _exit(124)
        }
        let model = SystemLanguageModel.default
        print("AVAILABILITY \(model.availability)")
        print("LOCALE \(model.supportsLocale()) CONTEXT \(model.contextSize)")
        fflush(stdout)
        let prompt = Prompt("Synthetic fact: an orchid needs indirect light. What light does the orchid need?")
        do {
            let tokens = try await model.tokenCount(for: prompt)
            print("TOKEN_COUNT \(tokens)")
        } catch { report(error, phase: "TOKEN_COUNT") }
        fflush(stdout)
        do {
            let session = LanguageModelSession(model: model,
                instructions: "Use only the provided synthetic fact. Answer in one short sentence.")
            let response = try await session.respond(to: prompt,
                options: GenerationOptions(maximumResponseTokens: 64))
            print("PLAIN_RESULT \(response.content)")
        } catch { report(error, phase: "PLAIN") }
        fflush(stdout)
        #if !SIMPLE_PROBE
        do {
            let session = LanguageModelSession(model: model,
                instructions: "Use only the provided synthetic fact.")
            let response = try await session.respond(to: prompt, generating: SyntheticFact.self,
                options: GenerationOptions(maximumResponseTokens: 64))
            print("STRUCTURED_RESULT \(response.content.light)")
        } catch { report(error, phase: "STRUCTURED") }
        fflush(stdout)
        #endif
        #if FULL_CAPD_PROBE
        do {
            let draft = try await OnDeviceAnswerModel().answer(
                question: "What light does an orchid need?", sources: [.init(number: 1,
                    source: .init(id: "synthetic-only", title: "Synthetic orchid",
                        excerpt: "An orchid needs indirect light. This is synthetic gardening evidence."))])
            print("CAPD_RESULT \(draft)")
        } catch { report(error, phase: "CAPD") }
        fflush(stdout)
        do {
            let answer = try await GroundedAnswerService(retriever: SyntheticReader())
                .answer("What light does an orchid need?")
            print("GROUNDED_RESULT \(answer)")
            print("GROUNDED_CITATION_IDS \(answer.sources.map(\.source.id))")
        } catch { report(error, phase: "GROUNDED") }
        fflush(stdout)
        #endif
    }

    static func report(_ error: any Error, phase: String) {
        // This executable uses fixed synthetic input only; never run it on library data.
        print("\(phase)_ERROR_TYPE \(String(reflecting: type(of: error)))")
        print("\(phase)_ERROR \(String(reflecting: error))")
        var current = error as NSError
        for _ in 0..<4 {
            print("\(phase)_NSERROR domain=\(current.domain) code=\(current.code) description=\(current.localizedDescription)")
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
    }
}

#if FULL_CAPD_PROBE
private struct SyntheticReader: AnswerRetrieving {
    func search(_ queries: [String], limit: Int) async throws -> [[AnswerEvidence]] {
        return queries.map { _ in
            guard limit > 0 else { return [] }
            return [.init(id: "synthetic-only", title: "Synthetic orchid",
                excerpt: "An orchid needs indirect light. This is synthetic gardening evidence.")]
        }
    }
}
#endif
