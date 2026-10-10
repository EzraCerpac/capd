import Foundation

/// Bounds the initial legacy read and decode as well as subsequent cache loads.
public actor LegacyWebsiteIconReader {
    private let load: @Sendable (URL) async throws -> Data?
    private var queued: [CheckedContinuation<Void, Never>] = []
    private(set) var admitted = 0
    private(set) var active = 0

    public init() {
        load = { file in
            try await Task.detached(priority: .utility) { try LegacyWebsiteIconPNG.read(at: file) }
                .value
        }
    }

    init(load: @escaping @Sendable (URL) async throws -> Data?) { self.load = load }

    public func read(at file: URL) async throws -> Data? {
        guard !Task.isCancelled, admitted < 16 else { return nil }
        admitted += 1
        if active < 2 {
            active += 1
        } else {
            await withCheckedContinuation { queued.append($0) }
        }
        defer {
            admitted -= 1
            if queued.isEmpty { active -= 1 } else { queued.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await load(file)
    }
}
