import CapdAppUI
import CapdKit
import Foundation
import Observation

/// Fetches the fork's `main` revision, a closure so tests can stub the network.
struct ReleaseClient: Sendable {
    var latestRevision: @Sendable () async throws -> String
}

extension ReleaseClient {
    static let forkMain = ReleaseClient {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/EzraCerpac/capd/commits/main")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Commit: Decodable { let sha: String }
        return try JSONDecoder().decode(Commit.self, from: data).sha
    }
}

enum SourceRevision {
    static func isValid(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy(\.isHexDigit)
    }
}

/// Checks the fork's `main` once a week and caches only its full commit SHA.
@MainActor
@Observable
final class UpdateChecker {
    static let upgradeCommand = "mise -C ~/.config/mise run local:capd-update"
    static let interval: TimeInterval = 7 * 24 * 60 * 60

    private let settings: AppSettings
    private let client: ReleaseClient
    private let now: @MainActor () -> Date
    private let sourceRevision: String?

    init(
        settings: AppSettings,
        client: ReleaseClient,
        sourceRevision: String? = Bundle.main.object(forInfoDictionaryKey: "CapdSourceRevision")
            as? String,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.settings = settings
        self.client = client
        self.sourceRevision = sourceRevision
        self.now = now
    }

    var availableVersion: String? {
        guard let latest = settings.latestKnownRevision,
            SourceRevision.isValid(latest),
            let sourceRevision,
            SourceRevision.isValid(sourceRevision),
            settings.checkedSourceRevision == sourceRevision,
            latest != sourceRevision
        else {
            return nil
        }
        return "fork main · \(latest.prefix(7))"
    }

    func checkIfDue() async {
        guard settings.checksForUpdates else { return }
        if settings.checkedSourceRevision == sourceRevision,
            let last = settings.lastUpdateCheck,
            now().timeIntervalSince(last) < Self.interval
        {
            return
        }
        // A failure leaves `lastUpdateCheck` alone: an offline pass retries on the
        // next one instead of going quiet for a week.
        guard let revision = try? await client.latestRevision(), SourceRevision.isValid(revision)
        else {
            return
        }
        settings.latestKnownRevision = revision
        settings.checkedSourceRevision = sourceRevision
        settings.lastUpdateCheck = now()
    }
}
