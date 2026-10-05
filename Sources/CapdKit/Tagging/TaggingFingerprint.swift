import CapdSync
import Foundation

enum TaggingFingerprint {
    static func of(_ capture: Capture) -> String {
        let input = TaggingInput(capture)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // An array of optional strings has no failing JSON encoding case.
        let bytes = try! encoder.encode([
            input.title, input.host, input.note, input.selection, input.excerpt,
        ])
        return "capd-tagging-input-v1:" + BlobReference(data: bytes).digest
    }
}
