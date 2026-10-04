import AppIntents
import CapdSystemIntegration

struct PhoneSystemIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [CapdSystemIntentsPackage.self] }
}

struct PhoneAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
