import Foundation

public enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case string(String)
    case number(Decimal)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

struct JSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

func decodeExtensions(_ decoder: any Decoder, known: Set<String>) throws -> [String: JSONValue] {
    let container = try decoder.container(keyedBy: JSONKey.self)
    return try Dictionary(
        uniqueKeysWithValues: container.allKeys.filter { !known.contains($0.stringValue) }.map {
            ($0.stringValue, try container.decode(JSONValue.self, forKey: $0))
        })
}

func encodeExtensions(_ fields: [String: JSONValue], to encoder: any Encoder, known: Set<String>)
    throws
{
    var container = encoder.container(keyedBy: JSONKey.self)
    for (key, value) in fields {
        guard !known.contains(key) else {
            throw EncodingError.invalidValue(
                value,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Extension collides with a known field"))
        }
        try container.encode(value, forKey: JSONKey(key))
    }
}

/// Original domain timestamps, separate from server revisions and delivery time.
public struct CaptureMetadata: Codable, Equatable, Sendable {
    public var updatedAt: Date?
    public var lastSeenAt: Date?
    public var reminderAt: Date?
    public let sourceAppBundleID: String?
    public var unknownFields: [String: JSONValue]

    public init(
        updatedAt: Date? = nil, lastSeenAt: Date? = nil, reminderAt: Date? = nil,
        sourceAppBundleID: String? = nil, unknownFields: [String: JSONValue] = [:]
    ) {
        self.updatedAt = updatedAt
        self.lastSeenAt = lastSeenAt
        self.reminderAt = reminderAt
        self.sourceAppBundleID = sourceAppBundleID
        self.unknownFields = unknownFields
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case updatedAt, lastSeenAt, reminderAt, sourceAppBundleID
    }
    private static var known: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        reminderAt = try container.decodeIfPresent(Date.self, forKey: .reminderAt)
        sourceAppBundleID = try container.decodeIfPresent(String.self, forKey: .sourceAppBundleID)
        unknownFields = try decodeExtensions(decoder, known: Self.known)
    }

    public func encode(to encoder: any Encoder) throws {
        try encodeExtensions(unknownFields, to: encoder, known: Self.known)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try container.encodeIfPresent(reminderAt, forKey: .reminderAt)
        try container.encodeIfPresent(sourceAppBundleID, forKey: .sourceAppBundleID)
    }
}

public enum ReminderUpdate: Codable, Equatable, Sendable {
    case set(Date)
    case clear
}
public enum TextUpdate: Codable, Equatable, Sendable {
    case set(String)
    case clear
}

public struct CaptureMetadataPatch: Codable, Equatable, Sendable {
    public var updatedAt: Date?
    public var lastSeenAt: Date?
    public var reminder: ReminderUpdate?
    public var unknownFields: [String: JSONValue]

    public init(
        updatedAt: Date? = nil, lastSeenAt: Date? = nil, reminder: ReminderUpdate? = nil,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.updatedAt = updatedAt
        self.lastSeenAt = lastSeenAt
        self.reminder = reminder
        self.unknownFields = unknownFields
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case updatedAt, lastSeenAt, reminder
    }
    private static var known: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        reminder = try c.decodeIfPresent(ReminderUpdate.self, forKey: .reminder)
        unknownFields = try decodeExtensions(decoder, known: Self.known)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeExtensions(unknownFields, to: encoder, known: Self.known)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try c.encodeIfPresent(reminder, forKey: .reminder)
    }
}

/// Descriptive hole-fill only. URL, hash, kind and attachment identity remain fixed.
public struct SourceContentPatch: Codable, Equatable, Sendable {
    public var title: String?
    public var selection: String?
    public var unknownFields: [String: JSONValue]
    public init(
        title: String? = nil, selection: String? = nil, unknownFields: [String: JSONValue] = [:]
    ) {
        self.title = title
        self.selection = selection
        self.unknownFields = unknownFields
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case title, selection }
    private static var known: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        selection = try c.decodeIfPresent(String.self, forKey: .selection)
        unknownFields = try decodeExtensions(decoder, known: Self.known)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeExtensions(unknownFields, to: encoder, known: Self.known)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(selection, forKey: .selection)
    }
}

public enum TaggingProcessingUpdate: Codable, Equatable, Sendable {
    public static let maximumFingerprintBytes = 256
    case processed(inputFingerprint: String)
    case pending
}

public struct GeneratedContentPatch: Codable, Equatable, Sendable {
    public var body: TextUpdate?
    public var bodyIsThin: Bool?
    public var ocrText: TextUpdate?
    public var tags: [String]?
    public var taggingProcessing: TaggingProcessingUpdate?
    public var unknownFields: [String: JSONValue]
    public init(
        body: TextUpdate? = nil, bodyIsThin: Bool? = nil, ocrText: TextUpdate? = nil,
        tags: [String]? = nil,
        taggingProcessing: TaggingProcessingUpdate? = nil,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.body = body
        self.bodyIsThin = bodyIsThin
        self.ocrText = ocrText
        self.tags = tags
        self.taggingProcessing = taggingProcessing
        self.unknownFields = unknownFields
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case body, bodyIsThin, ocrText, tags, taggingProcessing
    }
    private static var known: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)) }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        body = try c.decodeIfPresent(TextUpdate.self, forKey: .body)
        bodyIsThin = try c.decodeIfPresent(Bool.self, forKey: .bodyIsThin)
        ocrText = try c.decodeIfPresent(TextUpdate.self, forKey: .ocrText)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        taggingProcessing = try c.decodeIfPresent(
            TaggingProcessingUpdate.self, forKey: .taggingProcessing)
        unknownFields = try decodeExtensions(decoder, known: Self.known)
    }
    public func encode(to encoder: any Encoder) throws {
        try encodeExtensions(unknownFields, to: encoder, known: Self.known)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encodeIfPresent(bodyIsThin, forKey: .bodyIsThin)
        try c.encodeIfPresent(ocrText, forKey: .ocrText)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(taggingProcessing, forKey: .taggingProcessing)
    }
}

extension SyncHTTPAction {
    var requiresWebsiteIconContract: Bool {
        switch self {
        case .applyWebsiteIcon, .websiteIconChanges, .websiteIconBaselinePage, .uploadWebsiteIcon,
            .downloadWebsiteIcon:
            true
        default: false
        }
    }

    var requiresMetadataContract: Bool {
        guard case .apply(let operation) = self else { return false }
        switch operation.mutation {
        case .create(let capture):
            return capture.metadata != nil || !capture.unknownFields.isEmpty
                || !capture.source.unknownFields.isEmpty || !capture.generated.unknownFields.isEmpty
                || capture.noteConflicts.contains { !$0.unknownFields.isEmpty }
        case .edit(let edit):
            return edit.metadata != nil || edit.sourceContent != nil || edit.generatedPatch != nil
                || !edit.unknownFields.isEmpty || !(edit.note?.unknownFields.isEmpty ?? true)
                || !(edit.generated?.unknownFields.isEmpty ?? true)
        default: return false
        }
    }
}

extension GeneratedContent {
    var hasTaggingProcessing: Bool { taggingProcessed != nil || taggingInputFingerprint != nil }

    func validateTaggingProcessing() throws {
        guard bodyIsThin == nil || body != nil else { throw SyncError.invalidOperation }
        switch (taggingProcessed, taggingInputFingerprint) {
        case (nil, nil), (false?, nil): break
        case (true?, let fingerprint?): try validateTaggingFingerprint(fingerprint)
        default: throw SyncError.invalidOperation
        }
    }
}

func validateTaggingFingerprint(_ fingerprint: String) throws {
    guard !fingerprint.isEmpty,
        fingerprint.utf8.count <= TaggingProcessingUpdate.maximumFingerprintBytes
    else {
        throw SyncError.invalidOperation
    }
}

extension SyncHTTPAction {
    var requiresGeneratedProcessingContract: Bool {
        guard case .apply(let operation) = self else { return false }
        switch operation.mutation {
        case .create(let capture): return capture.generated.hasTaggingProcessing
        case .edit(let edit):
            return edit.generatedPatch?.taggingProcessing != nil
                || edit.generated?.hasTaggingProcessing == true
        default: return false
        }
    }
    var requiredEnvelopeVersion: Int {
        requiresWebsiteIconContract
            ? 5
            : requiresExtractionQualityContract
                ? 4
                : (requiresGeneratedProcessingContract ? 3 : (requiresMetadataContract ? 2 : 1))
    }

    var requiresExtractionQualityContract: Bool {
        guard case .apply(let operation) = self else { return false }
        switch operation.mutation {
        case .create(let capture): return capture.generated.bodyIsThin != nil
        case .edit(let edit):
            return edit.generatedPatch?.bodyIsThin != nil || edit.generated?.bodyIsThin != nil
        default: return false
        }
    }
}

extension SyncHTTPReply {
    func checkCapabilities(for action: SyncHTTPAction) throws {
        guard case .baseline = result else { throw SyncHTTPError.invalidResponse }
        try checkRequiredCapabilities(for: action)
    }

    func checkRequiredCapabilities(for action: SyncHTTPAction) throws {
        guard action.requiredEnvelopeVersion == 1 || metadataContractVersion == 1,
            !action.requiresGeneratedProcessingContract || generatedProcessingContractVersion == 1,
            !action.requiresExtractionQualityContract || extractionQualityContractVersion == 1,
            !action.requiresWebsiteIconContract || websiteIconContractVersion == 1
        else { throw SyncHTTPError.unsupportedVersion }
    }
}
