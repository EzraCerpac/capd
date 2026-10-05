import Foundation

public struct WebsiteIconIdentity: Hashable, Sendable {
    public let library: String
    public let generation: UUID
    public let originID: String
    public let revision: Int64
    public let normalizerVersion: Int
    public let digest: String

    public init(
        library: String, generation: UUID, originID: String, revision: Int64,
        normalizerVersion: Int, digest: String
    ) {
        self.library = library
        self.generation = generation
        self.originID = originID
        self.revision = revision
        self.normalizerVersion = normalizerVersion
        self.digest = digest
    }
}
