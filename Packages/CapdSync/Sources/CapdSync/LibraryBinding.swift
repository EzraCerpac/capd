import Foundation

/// Public enrollment identity, never a credential. serviceID survives host/URL changes.
public struct SyncLibraryBinding: Codable, Equatable, Sendable {
    public let libraryID: UUID
    public let serviceID: UUID

    public init(libraryID: UUID, serviceID: UUID) {
        self.libraryID = libraryID
        self.serviceID = serviceID
    }
}

public enum SyncBindingError: Error, Equatable, Sendable {
    case mismatch
    case bindingRequired
    case enrollmentRequiresEmptyLibrary
}

public protocol BoundSyncTransport: SyncTransport {
    var binding: SyncLibraryBinding { get }
    var deviceID: UUID { get }
}
