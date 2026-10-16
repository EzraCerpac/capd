import Foundation

/// The write-only native message accepted from the Safari capture popup.
public struct SafariCaptureRequest: Sendable {
    public static let command = "capd.capture-link.v1"
    public static let maximumURLBytes = 16_384
    public static let maximumTitleBytes = 4_096
    public static let maximumNoteBytes = 16_384

    public let capture: MobileCapture

    public init(message: Any) throws {
        guard let fields = message as? [String: String],
            Set(fields.keys) == ["command", "url", "title", "note"],
            fields["command"] == Self.command,
            let url = fields["url"], url.utf8.count <= Self.maximumURLBytes,
            let title = fields["title"], title.utf8.count <= Self.maximumTitleBytes,
            let note = fields["note"], note.utf8.count <= Self.maximumNoteBytes
        else { throw SafariCaptureError.invalidMessage }
        capture = try CaptureInput.make(text: url, title: title, note: note, isLink: true)
    }
}

public enum SafariCaptureError: Error {
    case invalidMessage
}
