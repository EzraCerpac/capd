import Foundation
import Testing

@MainActor
struct PhoneWebsiteIconTests {
    @Test func displayPreferencePersistsWithoutOwningAGenerationPolicy() throws {
        let name = "capd.synthetic-icon-display.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let icons = PhoneWebsiteIcons(defaults: defaults)
        #expect(icons.displayEnabled)
        icons.setDisplayEnabled(false)
        #expect(!icons.displayEnabled)
        #expect(!PhoneWebsiteIcons(defaults: defaults).displayEnabled)
        icons.setDisplayEnabled(true)
        #expect(PhoneWebsiteIcons(defaults: defaults).displayEnabled)
    }
}
