import CapdSync
import Foundation
import GRDB

public struct MobileCapture: Codable, Equatable, Sendable, Identifiable, FetchableRecord,
    MutablePersistableRecord
{
    public typealias Kind = CaptureSource.Kind
    public static let databaseTableName = "mobile_captures"
    public var localID: Int64?
    public let id: UUID
    public var kind: Kind
    public var url: String?
    public var title: String
    public var selection: String
    public var note: String
    public private(set) var createdAt: Date
    public var manualTags: [String] = []
    public var generatedTags: [String] = []
    public var body: String?
    public var ocrText: String?
    public var noteConflicts: [NoteVariant] = []
    public var seenCount = 1
    public var revision: Int64 = 0
    public var metadata: CaptureMetadata?
    public internal(set) var createdAtReferenceSeconds: Double?

    public init(
        id: UUID = UUID(), kind: Kind, url: String? = nil, title: String,
        selection: String = "", note: String = "", createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.title = title
        self.selection = selection
        self.note = note
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case localID, id, kind, url, title, selection, note, createdAt, manualTags, generatedTags,
            body, ocrText, noteConflicts, seenCount, revision, metadata, createdAtReferenceSeconds
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localID = try c.decodeIfPresent(Int64.self, forKey: .localID)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        selection = try c.decode(String.self, forKey: .selection)
        note = try c.decode(String.self, forKey: .note)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        manualTags = try c.decode([String].self, forKey: .manualTags)
        generatedTags = try c.decode([String].self, forKey: .generatedTags)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
        noteConflicts = try c.decode([NoteVariant].self, forKey: .noteConflicts)
        seenCount = try c.decode(Int.self, forKey: .seenCount)
        revision = try c.decode(Int64.self, forKey: .revision)
        metadata = try c.decodeIfPresent(CaptureMetadata.self, forKey: .metadata)
        createdAtReferenceSeconds = try c.decodeIfPresent(
            Double.self, forKey: .createdAtReferenceSeconds)
        if let seconds = createdAtReferenceSeconds {
            createdAt = Date(timeIntervalSinceReferenceDate: seconds)
        }
    }

    public static func databaseJSONEncoder(for column: String) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy =
            column == "metadata" ? .deferredToDate : .millisecondsSince1970
        return encoder
    }

    public static func databaseJSONDecoder(for column: String) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy =
            column == "metadata" ? .deferredToDate : .millisecondsSince1970
        return decoder
    }

    public static func databaseUUIDEncodingStrategy(for column: String)
        -> DatabaseUUIDEncodingStrategy
    {
        .uppercaseString
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { localID = inserted.rowID }
}

public enum CaptureValidationError: Error, LocalizedError {
    case emptyText, invalidURL
    public var errorDescription: String? {
        switch self {
        case .emptyText: "Add some text to save."
        case .invalidURL: "Enter a complete http or https URL."
        }
    }
}

public enum CaptureInput {
    public static func make(text: String, title: String = "", note: String = "", isLink: Bool)
        throws -> MobileCapture
    {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CaptureValidationError.emptyText }
        if isLink {
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
                ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
                url.user == nil, url.password == nil
            else { throw CaptureValidationError.invalidURL }
            return MobileCapture(
                kind: .link, url: url.absoluteString,
                title: title.isEmpty ? host : title, note: note)
        }
        return MobileCapture(
            kind: .text, title: title.isEmpty ? String(value.prefix(80)) : title,
            selection: value, note: note)
    }
}
