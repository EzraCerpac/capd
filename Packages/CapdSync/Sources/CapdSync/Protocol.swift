import Foundation

public struct CaptureSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case link, text, image }
    public var kind: Kind
    public var contentHash: String?
    public var url: String?
    public var host: String?
    public var title: String?
    public var selection: String?
    public var blob: BlobReference?
    public var unknownFields: [String: JSONValue] = [:]

    public init(
        kind: Kind, contentHash: String? = nil, url: String? = nil,
        host: String? = nil, title: String? = nil, selection: String? = nil,
        blob: BlobReference? = nil
    ) {
        self.kind = kind
        self.contentHash = contentHash
        self.url = url
        self.host = host
        self.title = title
        self.selection = selection
        self.blob = blob
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, contentHash, url, host, title, selection, blob
    }
    private static var known: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        selection = try c.decodeIfPresent(String.self, forKey: .selection)
        blob = try c.decodeIfPresent(BlobReference.self, forKey: .blob)
        unknownFields = try decodeExtensions(decoder, known: Self.known)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeExtensions(unknownFields, to: encoder, known: Self.known)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(contentHash, forKey: .contentHash)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(selection, forKey: .selection)
        try c.encodeIfPresent(blob, forKey: .blob)
    }

}

public struct GeneratedContent: Codable, Equatable, Sendable {
    public var body: String?
    public var ocrText: String?
    public var tags: [String]
    public var taggingProcessed: Bool?
    public var taggingInputFingerprint: String?
    public var unknownFields: [String: JSONValue] = [:]

    public init(
        body: String? = nil, ocrText: String? = nil, tags: [String] = [],
        taggingProcessed: Bool? = nil, taggingInputFingerprint: String? = nil
    ) {
        self.body = body
        self.ocrText = ocrText
        self.tags = tags
        self.taggingProcessed = taggingProcessed
        self.taggingInputFingerprint = taggingInputFingerprint
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case body, ocrText, tags, taggingProcessed, taggingInputFingerprint
    }
    private static var known: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
        tags = try c.decode([String].self, forKey: .tags)
        taggingProcessed = try c.decodeIfPresent(Bool.self, forKey: .taggingProcessed)
        taggingInputFingerprint = try c.decodeIfPresent(
            String.self, forKey: .taggingInputFingerprint)
        unknownFields = try decodeExtensions(decoder, known: Self.known)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeExtensions(unknownFields, to: encoder, known: Self.known)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(ocrText, forKey: .ocrText)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(taggingProcessed, forKey: .taggingProcessed)
        try c.encodeIfPresent(taggingInputFingerprint, forKey: .taggingInputFingerprint)
    }

}

public struct NoteVariant: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let value: String?
    public var unknownFields: [String: JSONValue] = [:]
    public init(operationID: UUID, value: String?, unknownFields: [String: JSONValue] = [:]) {
        self.operationID = operationID
        self.value = value
        self.unknownFields = unknownFields
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case operationID, value }
    private static var known: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try c.decode(UUID.self, forKey: .operationID)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        unknownFields = try decodeExtensions(decoder, known: Self.known)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeExtensions(unknownFields, to: encoder, known: Self.known)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operationID, forKey: .operationID)
        try c.encodeIfPresent(value, forKey: .value)
    }

}

public struct NoteEdit: Codable, Equatable, Sendable {
    public let value: String?
    public var unknownFields: [String: JSONValue] = [:]
    public let resolving: [UUID]

    public init(_ value: String?, resolving: [UUID] = []) {
        self.value = value
        self.resolving = resolving
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case value, resolving }
    private static var known: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        resolving = try c.decode([UUID].self, forKey: .resolving)
        unknownFields = try decodeExtensions(decoder, known: Self.known)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeExtensions(unknownFields, to: encoder, known: Self.known)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encode(resolving, forKey: .resolving)
    }

}

public struct CaptureEdit: Codable, Equatable, Sendable {
    public var note: NoteEdit?
    public var rating: Int?
    public var addTags: [String]
    public var removeTags: [String]
    public var generated: GeneratedContent?
    public var metadata: CaptureMetadataPatch?
    public var sourceContent: SourceContentPatch?
    public var generatedPatch: GeneratedContentPatch?
    public var unknownFields: [String: JSONValue] = [:]

    public init(
        note: NoteEdit? = nil, rating: Int? = nil, addTags: [String] = [],
        removeTags: [String] = [], generated: GeneratedContent? = nil,
        metadata: CaptureMetadataPatch? = nil, sourceContent: SourceContentPatch? = nil,
        generatedPatch: GeneratedContentPatch? = nil
    ) {
        self.note = note
        self.rating = rating
        self.addTags = addTags
        self.removeTags = removeTags
        self.generated = generated
        self.metadata = metadata
        self.sourceContent = sourceContent
        self.generatedPatch = generatedPatch
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case note, rating, addTags, removeTags, generated, metadata, sourceContent, generatedPatch
    }
    private static var known: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        note = try c.decodeIfPresent(NoteEdit.self, forKey: .note)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        addTags = try c.decode([String].self, forKey: .addTags)
        removeTags = try c.decode([String].self, forKey: .removeTags)
        generated = try c.decodeIfPresent(GeneratedContent.self, forKey: .generated)
        metadata = try c.decodeIfPresent(CaptureMetadataPatch.self, forKey: .metadata)
        sourceContent = try c.decodeIfPresent(SourceContentPatch.self, forKey: .sourceContent)
        generatedPatch = try c.decodeIfPresent(GeneratedContentPatch.self, forKey: .generatedPatch)
        unknownFields = try decodeExtensions(decoder, known: Self.known)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeExtensions(unknownFields, to: encoder, known: Self.known)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(rating, forKey: .rating)
        try c.encode(addTags, forKey: .addTags)
        try c.encode(removeTags, forKey: .removeTags)
        try c.encodeIfPresent(generated, forKey: .generated)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encodeIfPresent(sourceContent, forKey: .sourceContent)
        try c.encodeIfPresent(generatedPatch, forKey: .generatedPatch)
    }

}

public struct SharedCapture: Codable, Equatable, Sendable {
    public let id: UUID
    public internal(set) var source: CaptureSource
    public let createdAt: Date
    public var revision: Int64 = 0
    public var deleted = false
    public var seenCount = 1
    public var note: String?
    public var noteRevision: Int64 = 0
    public var noteOperationID: UUID
    public var noteConflicts: [NoteVariant] = []
    public var rating = 3
    public var manualTags: [String] = []
    public var generated = GeneratedContent()
    public var metadata: CaptureMetadata?
    public var unknownFields: [String: JSONValue] = [:]

    public init(
        id: UUID = UUID(), source: CaptureSource, createdAt: Date = Date(),
        note: String? = nil, metadata: CaptureMetadata? = nil
    ) {
        self.id = id
        self.source = source
        self.createdAt = createdAt
        self.note = note
        self.noteOperationID = UUID()
        self.metadata = metadata
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, source, createdAt, revision, deleted, seenCount, note, noteRevision,
            noteOperationID, noteConflicts, rating, manualTags, generated, metadata
    }
    private static var known: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        source = try c.decode(CaptureSource.self, forKey: .source)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        revision = try c.decode(Int64.self, forKey: .revision)
        deleted = try c.decode(Bool.self, forKey: .deleted)
        seenCount = try c.decode(Int.self, forKey: .seenCount)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        noteRevision = try c.decode(Int64.self, forKey: .noteRevision)
        noteOperationID = try c.decode(UUID.self, forKey: .noteOperationID)
        noteConflicts = try c.decode([NoteVariant].self, forKey: .noteConflicts)
        rating = try c.decode(Int.self, forKey: .rating)
        manualTags = try c.decode([String].self, forKey: .manualTags)
        generated = try c.decode(GeneratedContent.self, forKey: .generated)
        metadata = try c.decodeIfPresent(CaptureMetadata.self, forKey: .metadata)
        unknownFields = try decodeExtensions(decoder, known: Self.known)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeExtensions(unknownFields, to: encoder, known: Self.known)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source, forKey: .source)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(revision, forKey: .revision)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(seenCount, forKey: .seenCount)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(noteRevision, forKey: .noteRevision)
        try c.encode(noteOperationID, forKey: .noteOperationID)
        try c.encode(noteConflicts, forKey: .noteConflicts)
        try c.encode(rating, forKey: .rating)
        try c.encode(manualTags, forKey: .manualTags)
        try c.encode(generated, forKey: .generated)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }

}

public enum CaptureMutation: Codable, Equatable, Sendable {
    case create(SharedCapture)
    case edit(CaptureEdit)
    case recapture
    case delete
    case restore
}

public struct SyncOperation: Codable, Equatable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public let sequence: Int64
    public let captureID: UUID
    public let baseRevision: Int64
    public let predecessorID: UUID?
    public let requestIdentity: JSONValue?
    public let mutation: CaptureMutation

    public init(
        id: UUID = UUID(), deviceID: UUID, sequence: Int64, captureID: UUID,
        baseRevision: Int64, predecessorID: UUID? = nil, mutation: CaptureMutation,
        requestIdentity: JSONValue? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.sequence = sequence
        self.captureID = captureID
        self.baseRevision = baseRevision
        self.predecessorID = predecessorID
        self.requestIdentity = requestIdentity
        self.mutation = mutation
    }
}

public struct SyncReceipt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case accepted, noteConflict, deleted, staleRestore, missing, alreadyExists
    }
    public let operationID: UUID
    public let outcome: Outcome
    public let capture: SharedCapture?
}

public struct FeedChange: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let operationID: UUID
    public let deviceID: UUID
    public let sequence: Int64
    public let requestedCaptureID: UUID
    public let capture: SharedCapture
}

public struct FeedPage: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let changes: [FeedChange]
}

public struct Baseline: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let captures: [SharedCapture]
    public let deviceSequences: [UUID: Int64]
}

public enum SyncError: Error, Equatable, Codable, Sendable {
    case invalidOperation
    case operationIDReused
    case outOfOrder(expected: Int64)
    case recoverySequenceCollision
    case wrongDevice
    case cursorExpired
    case invalidCursor
    case invalidBlob
    case blobMissing
    case invalidOffset
    case acknowledgementLost
    case transportDisconnected
}

extension SyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transportDisconnected, .acknowledgementLost:
            "The connection closed. Try sync again when it is available."
        case .invalidBlob, .blobMissing:
            "An attachment could not be verified. Your changes remain saved locally."
        case .recoverySequenceCollision:
            "Queued changes overlap this device's server history. Your changes remain saved locally; recover with a new device enrollment."
        default:
            "The sync request could not be completed."
        }
    }
}

public protocol AcceptedCaptureReader: Sendable {
    func acceptedCaptures() throws -> [SharedCapture]
}

/// Portable operations; adapters supply the wire protocol and authorization boundary.
public protocol SyncTransport: Sendable {
    func apply(_ operation: SyncOperation) throws -> SyncReceipt
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage
    func baseline() throws -> Baseline
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws
    func download(_ blob: BlobReference) throws -> Data
}
