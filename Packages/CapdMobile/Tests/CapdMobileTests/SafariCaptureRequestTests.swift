import Foundation
import Testing

@testable import CapdMobile

private func safariMessage(
    url: String = "https://example.invalid/article", title: String = "Reviewed title",
    note: String = "My note"
) -> [String: String] {
    ["command": SafariCaptureRequest.command, "url": url, "title": title, "note": note]
}

@Test func safariCapturePreservesReviewedLinkTitleAndNote() throws {
    let capture = try SafariCaptureRequest(message: safariMessage()).capture
    #expect(capture.kind == .link)
    #expect(capture.url == "https://example.invalid/article")
    #expect(capture.title == "Reviewed title")
    #expect(capture.note == "My note")
    #expect(capture.selection.isEmpty && capture.body == nil && capture.ocrText == nil)
    #expect(
        try SafariCaptureRequest(message: safariMessage(title: "")).capture.title
            == "example.invalid")
}

@Test(arguments: [
    "", "about:blank", "file:///private/example", "javascript:alert(1)",
    "data:text/plain,example", "https:///", "https://user:secret@example.invalid/",
    "https://user@example.invalid/",
])
func safariCaptureRejectsUnsupportedOrCredentialedURL(_ url: String) {
    #expect(throws: (any Error).self) {
        try SafariCaptureRequest(message: safariMessage(url: url))
    }
}

@Test func safariCaptureRejectsUnknownCommandsFieldsAndTypes() {
    var unknownCommand = safariMessage()
    unknownCommand["command"] = "readLibrary"
    var unknownField = safariMessage()
    unknownField["credential"] = "synthetic-rejected"
    var missingField = safariMessage()
    missingField.removeValue(forKey: "note")
    let malformed: [Any] = [
        unknownCommand, unknownField, missingField, "not an object", ["command": true],
        ["command": SafariCaptureRequest.command, "url": NSNull(), "title": "", "note": ""],
    ]
    for message in malformed {
        #expect(throws: (any Error).self) { try SafariCaptureRequest(message: message) }
    }
}

@Test func safariCaptureEnforcesUTF8FieldBudgets() throws {
    let title = String(repeating: "🧭", count: SafariCaptureRequest.maximumTitleBytes / 4)
    let note = String(repeating: "é", count: SafariCaptureRequest.maximumNoteBytes / 2)
    #expect(
        try SafariCaptureRequest(message: safariMessage(title: title, note: note)).capture.note
            == note)
    for message in [
        safariMessage(title: title + "a"), safariMessage(note: note + "a"),
        safariMessage(url: "https://example.invalid/" + String(repeating: "a", count: 16_384)),
    ] {
        #expect(throws: SafariCaptureError.invalidMessage) {
            try SafariCaptureRequest(message: message)
        }
    }
}

@Test func safariCaptureUsesExistingLocalOutboxAndReopensInApp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-safari-\(UUID())"
    )
    .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try MobileLibrarySession.open(root: root, role: .shareExtension)
    #expect(await session.adapter.availability() == .unconfigured)
    let saved = try session.save(SafariCaptureRequest(message: safariMessage()).capture)
    #expect(try session.store.pending().count == 1)
    let app = try MobileLibrarySession.open(root: root, role: .app)
    #expect(try app.capture(id: saved.capture.id)?.capture == saved.capture)
    #expect(try app.store.pending() == session.store.pending())
}
