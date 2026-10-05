import Foundation

@MainActor
enum MacSystemSearchCleanup {
    static func run(
        remove: () async throws -> Void,
        reportIssue: (String?) -> Void,
        waitToRetry: () async throws -> Void = { try await Task.sleep(for: .seconds(30)) }
    ) async {
        while !Task.isCancelled {
            do {
                try await remove()
                reportIssue(nil)
                return
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                reportIssue(error.localizedDescription)
            }
            do { try await waitToRetry() } catch { return }
        }
    }
}
