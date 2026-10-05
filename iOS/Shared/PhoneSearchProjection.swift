import CapdMobile
import CapdSystemIntegration
import Foundation

enum PhoneSearchProjection {
    static let indexName = "dev.jxd.capd.phone.captures"
    static let enabledKey = "capd.system-search.enabled"
    static let indexedLibraryKey = "capd.system-search.indexed-library-id"

    /// The session owner supplies the canonical record and library identity after saving.
    static func capture(_ canonical: MobileCapture, libraryID: UUID) -> SearchCapture {
        let derivedTitle = String(
            canonical.selection.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let title =
            canonical.kind == .text && canonical.title == derivedTitle
            ? "Saved text" : canonical.title
        return SearchCapture(
            reference: CaptureReference(libraryID: libraryID, captureID: canonical.id),
            title: title,
            text: canonical.manualTags.prefix(32).map { String($0.prefix(80)) }.joined(
                separator: " "),
            keywords: canonical.manualTags, revision: canonical.revision)
    }

    static func isAuthorized(libraryID: UUID, defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: enabledKey)
            && defaults.string(forKey: indexedLibraryKey).flatMap(UUID.init(uuidString:))
                == libraryID
    }
}
