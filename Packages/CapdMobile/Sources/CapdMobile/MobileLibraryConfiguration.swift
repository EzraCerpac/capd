import CapdSync
import Foundation

/// Public routing metadata only. Credentials never enter the app-group selector.
public struct MobileLibraryConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let generation: UUID
    public let enrollment: SyncEnrollment?
    public let relativeDatabasePath: String

    public static let legacy = MobileLibraryConfiguration(
        generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, enrollment: nil)

    public init(generation: UUID, enrollment: SyncEnrollment?) {
        version = 1
        self.generation = generation
        self.enrollment = enrollment
        relativeDatabasePath =
            enrollment == nil
            ? "Library/captures.sqlite"
            : "ConnectedLibraries/\(generation.uuidString)/captures.sqlite"
    }

    func validate() throws {
        guard version == 1,
            relativeDatabasePath
                == (enrollment == nil
                    ? "Library/captures.sqlite"
                    : "ConnectedLibraries/\(generation.uuidString)/captures.sqlite")
        else { throw MobileActivationError.invalidConfiguration }
        if let enrollment {
            let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            guard
                ![
                    generation, enrollment.deviceID, enrollment.binding.libraryID,
                    enrollment.binding.serviceID,
                ].contains(zero)
            else { throw MobileActivationError.invalidConfiguration }
            _ = try SyncEnrollment(
                endpoint: enrollment.endpoint, binding: enrollment.binding,
                deviceID: enrollment.deviceID)
        } else if self != Self.legacy {
            throw MobileActivationError.invalidConfiguration
        }
    }

    public func databaseURL(in root: URL) throws -> URL {
        try validate()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(relativeDatabasePath)
        // A selector cannot redirect stores through a symlink, even inside the group.
        guard candidate.resolvingSymlinksInPath() == candidate else {
            throw MobileActivationError.invalidConfiguration
        }
        return candidate
    }
}

public enum MobileActivationError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration, transitionBusy, sessionReplaced, stalePreparation
    case invalidHandoff, identityAlreadyUsed, missingImport, fileTooLarge
    case rollbackFailed, credentialCleanupRequired

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The saved library connection is invalid. Your libraries are retained."
        case .transitionBusy:
            "The library is busy. Your draft is retained; try again shortly."
        case .sessionReplaced: "The active library changed. Reopen the library and try again."
        case .stalePreparation:
            "Captures changed after the backup. Prepare and review a new backup before connecting."
        case .invalidHandoff: "The import confirmation does not match this backup and library."
        case .identityAlreadyUsed:
            "This device identity already has history. Use a fresh device connection."
        case .missingImport: "The imported captures are not present in the connected library."
        case .fileTooLarge: "The setup file exceeds the supported size."
        case .rollbackFailed:
            "The library selector could not be restored. Both libraries are retained; review setup before saving."
        case .credentialCleanupRequired:
            "Setup did not complete and its new device credential needs removal. The original library is retained."
        }
    }
}
