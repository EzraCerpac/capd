import Foundation

public struct CaptureReference: Codable, Hashable, Sendable, Identifiable {
    public let libraryID: UUID
    public let captureID: UUID
    public var id: String {
        "capd.v1.\(libraryID.uuidString.lowercased()).\(captureID.uuidString.lowercased())"
    }

    public init(libraryID: UUID, captureID: UUID) {
        self.libraryID = libraryID
        self.captureID = captureID
    }

    public init?(identifier: String) {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "capd", parts[1] == "v1",
            let library = UUID(uuidString: String(parts[2])),
            let capture = UUID(uuidString: String(parts[3]))
        else { return nil }
        self.init(libraryID: library, captureID: capture)
    }
}

public enum CaptureRoute: Equatable, Sendable {
    case open(CaptureReference)
    case find(String)

    public var url: URL {
        var components = URLComponents()
        components.scheme = "capd"
        switch self {
        case .open(let reference):
            components.host = "open"
            components.queryItems = [
                URLQueryItem(name: "library", value: reference.libraryID.uuidString.lowercased()),
                URLQueryItem(name: "id", value: reference.captureID.uuidString.lowercased()),
            ]
        case .find(let query):
            components.host = "find"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return components.url!
    }

    public init?(url: URL) {
        guard url.absoluteString.utf8.count <= 8192,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "capd", components.user == nil, components.password == nil,
            components.port == nil, components.path.isEmpty, components.fragment == nil,
            let items = components.queryItems,
            Set(items.map(\.name)).count == items.count,
            items.allSatisfy({ $0.value != nil })
        else { return nil }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        switch components.host {
        case "open":
            guard Set(values.keys) == ["library", "id"],
                let library = values["library"].flatMap(UUID.init(uuidString:)),
                let capture = values["id"].flatMap(UUID.init(uuidString:))
            else { return nil }
            self = .open(CaptureReference(libraryID: library, captureID: capture))
        case "find":
            guard Set(values.keys) == ["q"], let query = values["q"], query.count <= 512
            else { return nil }
            self = .find(query)
        default: return nil
        }
    }
}

public struct SearchCapture: Codable, Equatable, Sendable, Identifiable {
    public let reference: CaptureReference
    public var title: String
    public var text: String
    public var keywords: [String]
    public var revision: Int64
    public var deleted: Bool
    public var id: String { reference.id }
    var isBounded: Bool {
        title.count <= 256 && text.count <= 8192 && keywords.count <= 32
            && keywords.allSatisfy { $0.count <= 80 } && revision >= 0
    }

    public init(
        reference: CaptureReference, title: String, text: String = "", keywords: [String] = [],
        revision: Int64 = 0, deleted: Bool = false
    ) {
        self.reference = reference
        self.title = String(title.prefix(256))
        self.text = String(text.prefix(8192))
        self.keywords = keywords.prefix(32).map { String($0.prefix(80)) }
        self.revision = revision
        self.deleted = deleted
    }
}

public enum SystemIntegrationError: Error, LocalizedError, Equatable {
    case unavailable, privacyDisabled, missingCapture, invalidInput, snapshotTooLarge,
        invalidSnapshot, actionPending

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Open capd to use this action."
        case .privacyDisabled: "Enable system search in capd to find saved captures here."
        case .missingCapture: "This capture is no longer available in this library."
        case .invalidInput: "Enter up to 512 search characters or 8192 text characters."
        case .snapshotTooLarge: "This library exceeds the system search snapshot limit."
        case .invalidSnapshot: "System search could not validate the library snapshot."
        case .actionPending: "Review the pending action in capd, then try again."
        }
    }
}
