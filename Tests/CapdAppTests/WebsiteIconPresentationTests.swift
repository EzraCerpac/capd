import Foundation
import Testing

@testable import CapdAppUI
@testable import CapdKit

@MainActor
struct WebsiteIconPresentationTests {
    @Test func searchAndHUDCarryTheActualURLAndKeepActionsIndependent() throws {
        let raw = "https://www.sqlite.org:443/page?q=synthetic#section"
        let capture = Capture(kind: .link, url: raw, host: "sqlite.org", createdAt: Date())
        let expected = try #require(URL(string: raw))
        let row = SearchRowContent(
            SearchHit(capture: capture, snippet: nil, score: nil), now: Date())
        #expect(row.sourceURL == expected)
        let saved = HUDContent.outcome(.captured(capture), fallbackNote: nil, now: Date())
        #expect(saved.sourceURL == expected)
        #expect(saved.actionURL == nil)
        #expect(HUDContent.reminder(capture).sourceURL == expected)
        #expect(HUDContent.reminder(capture).actionURL == expected)
        #expect(HUDContent.copied(capture).sourceURL == expected)
        #expect(HUDContent.previouslySaved(capture, now: Date()).sourceURL == expected)
    }

    @Test func textAndImageDoNotAcquireWebsiteIconsFromIncidentalURLs() {
        for kind in [CaptureKind.text, .image] {
            let capture = Capture(kind: kind, url: "https://sqlite.org", createdAt: Date())
            let row = SearchRowContent(
                SearchHit(capture: capture, snippet: nil, score: nil), now: Date())
            #expect(row.sourceURL == nil)
            #expect(
                HUDContent.outcome(.captured(capture), fallbackNote: nil, now: Date()).sourceURL
                    == nil)
        }
    }

    @Test func generationPolicyDefaultsOffAndOnlyChangedValuesReachTheStoreHook() throws {
        let name = "capd.synthetic-icon-settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.websiteIconsEnabled == false)
        var changes: [Bool] = []
        settings.saveWebsiteIcons = { changes.append($0) }
        settings.websiteIconsEnabled = true
        settings.websiteIconsEnabled = true
        settings.websiteIconsEnabled = false
        #expect(changes == [true, false])
    }
}
