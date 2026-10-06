import CapdWebsiteIcons
import Foundation
import Observation

@MainActor
@Observable
final class PhoneWebsiteIcons {
    private static let preferenceKey = "capd.website-icons.display-enabled"
    private let defaults: UserDefaults
    private(set) var displayEnabled: Bool
    let cache = WebsiteIconCache()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayEnabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    func setDisplayEnabled(_ enabled: Bool) {
        displayEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
    }
}
