import Foundation

public enum GenerationGateError: Error, Sendable {
    case syncUnavailable
    case changed
}

/// Requires a fresh observation before work and rejects a result if its observed revision changed.
public struct GenerationGate: Sendable {
    private let observe: @Sendable () async throws -> Int64

    public init(observe: @escaping @Sendable () async throws -> Int64) {
        self.observe = observe
    }

    func begin() async throws -> Int64 {
        try Task.checkCancellation()
        let revision = try await observe()
        try Task.checkCancellation()
        return revision
    }

    func validate(_ revision: Int64) async throws {
        guard try await begin() == revision else { throw GenerationGateError.changed }
    }
}
