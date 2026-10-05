import Foundation

public struct MobileSystemSearchSnapshot: Sendable {
    public let revision: UUID?
    public let captures: [MobileCapture]
}

/// Potentially indexed scopes survive failed OS writes and library replacement.
/// Read and mutate only inside withLease or MobileLibrarySession.withSystemSearchLease.
public struct MobileSystemSearchJournal: Sendable {
    private struct State: Codable {
        let version: Int
        var libraries: [UUID]
    }
    private let url: URL

    public init(root: URL) {
        url = root.appendingPathComponent("system-search-repair.json")
    }

    /// Allows scoped index cleanup even when the selected database cannot be opened.
    public static func withLease<T: Sendable>(
        root: URL, _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let library = try MobileLibraryLease(root: root, exclusive: false)
        let search = try MobileLibraryLease(
            root: root, exclusive: true, fileName: ".system-search.lock")
        defer { withExtendedLifetime((library, search)) {} }
        return try await operation()
    }

    public func libraries() throws -> [UUID] { try read().libraries }

    public func begin(_ libraryID: UUID) throws {
        var state = try read()
        if !state.libraries.contains(libraryID) { state.libraries.append(libraryID) }
        try write(state)
    }

    public func removed(_ libraryID: UUID) throws {
        var state = try read()
        state.libraries.removeAll { $0 == libraryID }
        try write(state)
    }

    private func read() throws -> State {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return State(version: 1, libraries: [])
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            (values.fileSize ?? Int.max) <= 65_536
        else {
            throw MobileActivationError.invalidConfiguration
        }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        guard state.version == 1, state.libraries.count <= 1000,
            Set(state.libraries).count == state.libraries.count
        else {
            throw MobileActivationError.invalidConfiguration
        }
        return state
    }

    private func write(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(state).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
