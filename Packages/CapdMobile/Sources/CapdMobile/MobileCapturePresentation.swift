import Foundation

public enum MobileCapturePresentation {
    public static func symbol(for capture: MobileCapture) -> String {
        switch capture.kind {
        case .link: "link"
        case .text: "text.alignleft"
        case .image: "photo"
        }
    }

    public static func metadata(for capture: MobileCapture) -> String {
        switch capture.kind {
        case .link:
            if let raw = capture.url, let url = URLComponents(string: raw), let host = url.host {
                return host + (url.path == "/" ? "" : url.path)
            }
            return "link"
        case .text:
            return "text · \(capture.selection.count.formatted()) chars"
        case .image:
            return "image"
        }
    }

    public static func manualTagsToSave(draft: String, original: [String]) -> [String] {
        guard draft != original.joined(separator: " ") else { return original }
        return Array(Set(draft.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }))
            .sorted()
    }

    public static func recognizedText(for capture: MobileCapture) -> String? {
        guard let text = capture.ocrText, !text.isEmpty else { return nil }
        return text
    }
}
