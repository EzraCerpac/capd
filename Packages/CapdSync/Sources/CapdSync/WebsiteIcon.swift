import Foundation

public struct WebsiteIconOrigin: Codable, Equatable, Hashable, Sendable {
    public let canonicalHTTPSOrigin: String
    public let host: String
    public var id: String { BlobReference(data: Data(canonicalHTTPSOrigin.utf8)).digest }

    public init?(url: String) {
        guard let components = URLComponents(string: url),
            components.scheme?.lowercased() == "https", components.user == nil,
            components.password == nil, components.port == nil || components.port == 443,
            let hostname = components.host?.lowercased(), hostname.utf8.count <= 253
        else { return nil }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        let reserved: Set<String> = [
            "localhost", "local", "internal", "home", "lan", "test", "invalid", "example",
            "onion", "arpa", "alt",
        ]
        guard labels.count >= 2, let last = labels.last,
            !reserved.contains(String(last)),
            last.utf8.contains(where: { (97...122).contains($0) }),
            labels.allSatisfy({ label in
                (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy {
                        (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                    }
            })
        else { return nil }
        host = hostname
        canonicalHTTPSOrigin = "https://\(hostname)"
    }

    private enum CodingKeys: String, CodingKey { case canonicalHTTPSOrigin }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try values.decode(String.self, forKey: .canonicalHTTPSOrigin)
        guard let origin = Self(url: raw), origin.canonicalHTTPSOrigin == raw else {
            throw DecodingError.dataCorruptedError(
                forKey: .canonicalHTTPSOrigin, in: values,
                debugDescription: "Invalid website origin")
        }
        self = origin
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(canonicalHTTPSOrigin, forKey: .canonicalHTTPSOrigin)
    }
}

public struct WebsiteIconContent: Codable, Equatable, Sendable {
    public let blob: BlobReference
    public let normalizerVersion: Int
    public let fetchedAt: Date

    public init(blob: BlobReference, normalizerVersion: Int = 1, fetchedAt: Date = Date()) {
        self.blob = blob
        self.normalizerVersion = normalizerVersion
        self.fetchedAt = fetchedAt
    }

    public func validate() throws {
        try blob.validate()
        guard normalizerVersion == 1, (1...262_144).contains(blob.byteCount),
            fetchedAt.timeIntervalSince1970.isFinite
        else { throw SyncError.invalidOperation }
    }
}

public struct WebsiteIconRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let origin: WebsiteIconOrigin
    public let revision: Int64
    public let deleted: Bool
    public let content: WebsiteIconContent?

    public var id: String { origin.id }

    public init(
        origin: WebsiteIconOrigin, revision: Int64, deleted: Bool = false,
        content: WebsiteIconContent?
    ) {
        version = 1
        self.origin = origin
        self.revision = revision
        self.deleted = deleted
        self.content = content
    }

    public func validate() throws {
        guard version == 1, revision >= 0, deleted || content != nil else {
            throw SyncError.invalidOperation
        }
        try content?.validate()
    }
}

public enum WebsiteIconMutation: Codable, Equatable, Sendable {
    case upsert(WebsiteIconContent)
    case tombstone
}

public struct WebsiteIconOperation: Codable, Equatable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let sequence: Int64
    public let origin: WebsiteIconOrigin
    public let baseRevision: Int64
    public let mutation: WebsiteIconMutation

    public init(
        id: UUID = UUID(), deviceID: UUID, sequence: Int64, origin: WebsiteIconOrigin,
        baseRevision: Int64, mutation: WebsiteIconMutation
    ) {
        self.id = id
        self.deviceID = deviceID
        self.sequence = sequence
        self.origin = origin
        self.baseRevision = baseRevision
        self.mutation = mutation
    }

    public func validate() throws {
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        guard id != zero, deviceID != zero, sequence > 0, baseRevision >= 0 else {
            throw SyncError.invalidOperation
        }
        if case .upsert(let content) = mutation { try content.validate() }
    }
}

public struct WebsiteIconReceipt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case accepted, stale, unreferenced }
    public let operationID: UUID
    public let outcome: Outcome
    public let record: WebsiteIconRecord?

    public init(operationID: UUID, outcome: Outcome, record: WebsiteIconRecord?) {
        self.operationID = operationID
        self.outcome = outcome
        self.record = record
    }
}

public struct WebsiteIconFeedChange: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let record: WebsiteIconRecord
    public let operationID: UUID?
    public let deviceID: UUID?
    public let sequence: Int64?

    public init(
        cursor: Int64, record: WebsiteIconRecord, operationID: UUID? = nil,
        deviceID: UUID? = nil, sequence: Int64? = nil
    ) {
        self.cursor = cursor
        self.record = record
        self.operationID = operationID
        self.deviceID = deviceID
        self.sequence = sequence
    }
}

public struct WebsiteIconFeedPage: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let changes: [WebsiteIconFeedChange]

    public init(cursor: Int64, changes: [WebsiteIconFeedChange]) {
        self.cursor = cursor
        self.changes = changes
    }
}

public struct WebsiteIconBaseline: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let records: [WebsiteIconRecord]
    public let deviceSequences: [UUID: Int64]
    public let totalIconCount: Int

    public init(
        cursor: Int64, records: [WebsiteIconRecord], deviceSequences: [UUID: Int64],
        totalIconCount: Int? = nil
    ) {
        self.cursor = cursor
        self.records = records
        self.deviceSequences = deviceSequences
        self.totalIconCount = totalIconCount ?? records.count
    }
}

public enum WebsiteIconError: Error, Equatable, Sendable {
    case pendingOperation
}

public protocol WebsiteIconSyncTransport: BoundSyncTransport {
    func applyWebsiteIcon(_ operation: WebsiteIconOperation) throws -> WebsiteIconReceipt
    func websiteIconChanges(after cursor: Int64, limit: Int) throws -> WebsiteIconFeedPage
    func websiteIconBaseline() throws -> WebsiteIconBaseline
    func checkWebsiteIconCapability() throws
}
