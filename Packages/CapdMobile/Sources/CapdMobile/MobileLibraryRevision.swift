import Foundation

public struct MobileLibraryRevision: Equatable, Sendable {
    public let cursor: Int64
    public let sequence: Int64
    public let pendingChanges: Int
    public let rejectedChanges: Int
}
