import Foundation

package enum Browser: String, CaseIterable {
    case safari = "com.apple.Safari"
    case chrome = "com.google.Chrome"
    case arc = "company.thebrowser.Browser"
    case firefox = "org.mozilla.firefox"
    case zen = "app.zen-browser.zen"
    case librewolf = "org.mozilla.librewolf"
    case waterfox = "net.waterfox.waterfox"
    case search = "com.officecommun.search"

    package init?(bundleID: String) {
        self.init(rawValue: bundleID)
    }

    package var usesAccessibilityTabReader: Bool {
        switch self {
        case .safari, .chrome, .arc: false
        case .firefox, .zen, .librewolf, .waterfox, .search: true
        }
    }

    package var supportsTabExtraction: Bool {
        switch self {
        case .safari, .chrome, .arc: true
        case .firefox, .zen, .librewolf, .waterfox, .search: false
        }
    }
}
