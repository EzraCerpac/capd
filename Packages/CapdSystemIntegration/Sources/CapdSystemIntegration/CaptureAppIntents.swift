import AppIntents
import Foundation

public struct CaptureEntity: AppEntity, Sendable {
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Saved Capture")
    public static let defaultQuery = CaptureEntityQuery()
    public let id: String
    public let title: String
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    public init(_ capture: SearchCapture) {
        id = capture.id
        title = capture.title
    }
}

public struct CaptureEntityQuery: EntityStringQuery {
    public init() {}

    @MainActor
    public func entities(for identifiers: [String]) async throws -> [CaptureEntity] {
        guard identifiers.allSatisfy({ CaptureReference(identifier: $0) != nil }) else {
            throw SystemIntegrationError.invalidInput
        }
        return try CaptureIntentRuntime.shared.resolve(
            identifiers.compactMap(CaptureReference.init(identifier:))
        ).map(CaptureEntity.init)
    }

    @MainActor
    public func entities(matching string: String) async throws -> [CaptureEntity] {
        try CaptureIntentRuntime.shared.search(string).map(CaptureEntity.init)
    }

    public func suggestedEntities() async throws -> [CaptureEntity] { [] }
}

public struct FindCapturesIntent: AppIntent {
    public static let title: LocalizedStringResource = "Find Captures"
    public static let description = IntentDescription(
        "Open capd and search the local saved library.")
    public static let openAppWhenRun = true
    @available(iOS 26, macOS 26, *)
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static var parameterSummary: some ParameterSummary {
        Summary("Find captures matching \(\.$query)")
    }

    @Parameter(title: "Search") public var query: String
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try CaptureIntentRuntime.shared.perform(.find(query))
        return .result()
    }
}

public struct OpenCaptureIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Capture"
    public static let description = IntentDescription("Open one saved capture in capd.")
    public static let openAppWhenRun = true
    @available(iOS 26, macOS 26, *)
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static var parameterSummary: some ParameterSummary { Summary("Open \(\.$capture)") }

    @Parameter(title: "Capture") public var capture: CaptureEntity
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        guard let reference = CaptureReference(identifier: capture.id) else {
            throw SystemIntegrationError.invalidInput
        }
        try CaptureIntentRuntime.shared.perform(.open(reference))
        return .result()
    }
}

public struct CaptureTextIntent: AppIntent {
    public static let title: LocalizedStringResource = "Draft Text Capture"
    public static let description = IntentDescription(
        "Review text in capd before saving it as a capture.")
    public static let openAppWhenRun = true
    @available(iOS 26, macOS 26, *)
    public static var supportedModes: IntentModes { .foreground(.immediate) }
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    public static var parameterSummary: some ParameterSummary {
        Summary("Draft a capture of \(\.$text)")
    }

    @Parameter(title: "Text") public var text: String
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        try CaptureIntentRuntime.shared.perform(.stageText(text))
        return .result()
    }
}

public enum CapdShortcutCatalog {
    @AppShortcutsBuilder
    public static var shortcuts: [AppShortcut] {
        AppShortcut(
            intent: FindCapturesIntent(), phrases: ["Find captures in \(.applicationName)"],
            shortTitle: "Find Captures", systemImageName: "magnifyingglass")
        AppShortcut(
            intent: OpenCaptureIntent(), phrases: ["Open a capture in \(.applicationName)"],
            shortTitle: "Open Capture", systemImageName: "bookmark")
        AppShortcut(
            intent: CaptureTextIntent(), phrases: ["Draft a text capture in \(.applicationName)"],
            shortTitle: "Draft Text", systemImageName: "square.and.pencil")
    }
}

public struct CapdSystemIntentsPackage: AppIntentsPackage {}
