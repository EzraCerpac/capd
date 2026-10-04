import Foundation

public enum CaptureAction: Equatable, Sendable {
    case find(String)
    case open(CaptureReference)
    case stageText(String)
}

@MainActor
public protocol CaptureActionHost: AnyObject {
    var systemSearchEnabled: Bool { get }
    func prepareForIntent() async throws
    func search(_ query: String) throws -> [SearchCapture]
    func resolve(_ reference: CaptureReference) throws -> SearchCapture?
    func handle(_ action: CaptureAction) throws
}

extension CaptureActionHost {
    public func prepareForIntent() async throws {}
}

@MainActor
public final class CaptureIntentRuntime {
    public static let shared = CaptureIntentRuntime()
    public weak var host: (any CaptureActionHost)?

    public init() {}

    public func prepareForIntent() async throws {
        try Task.checkCancellation()
        try await availableHost().prepareForIntent()
        try Task.checkCancellation()
    }

    public func search(_ query: String) throws -> [SearchCapture] {
        try Task.checkCancellation()
        guard query.count <= 512 else { throw SystemIntegrationError.invalidInput }
        let host = try availableHost()
        guard host.systemSearchEnabled else { throw SystemIntegrationError.privacyDisabled }
        let results = try host.search(query).filter { !$0.deleted }
        var seen = Set<String>()
        return Array(results.filter { seen.insert($0.id).inserted }.prefix(20))
    }

    public func resolve(_ references: [CaptureReference]) throws -> [SearchCapture] {
        try Task.checkCancellation()
        let host = try availableHost()
        guard host.systemSearchEnabled else { throw SystemIntegrationError.privacyDisabled }
        guard references.count <= 100 else { throw SystemIntegrationError.invalidInput }
        var seen = Set<String>()
        return try references.filter { seen.insert($0.id).inserted }.compactMap {
            guard let capture = try host.resolve($0), capture.reference == $0, !capture.deleted
            else { return nil }
            return capture
        }
    }

    public func perform(_ action: CaptureAction) throws {
        try Task.checkCancellation()
        let host = try availableHost()
        switch action {
        case .find(let query):
            guard host.systemSearchEnabled else { throw SystemIntegrationError.privacyDisabled }
            guard query.count <= 512 else { throw SystemIntegrationError.invalidInput }
        case .open(let reference):
            guard host.systemSearchEnabled else { throw SystemIntegrationError.privacyDisabled }
            guard let capture = try host.resolve(reference), capture.reference == reference,
                !capture.deleted
            else { throw SystemIntegrationError.missingCapture }
        case .stageText(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                text.count <= 8192
            else { throw SystemIntegrationError.invalidInput }
        }
        try Task.checkCancellation()
        try host.handle(action)
    }

    private func availableHost() throws -> any CaptureActionHost {
        guard let host else { throw SystemIntegrationError.unavailable }
        return host
    }
}
