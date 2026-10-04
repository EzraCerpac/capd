import CapdSync
import XCTest

final class SyncIntegrationUITests: XCTestCase {
    @MainActor
    func testSimulatorAndPortableMacShareOneDurableProtocol() throws {
        continueAfterFailure = false
        guard
            let authorityPort = UInt16(
                ProcessInfo.processInfo.environment["CAPD_REFERENCE_PORT"] ?? ""),
            let macPort = UInt16(ProcessInfo.processInfo.environment["CAPD_MAC_FIXTURE_PORT"] ?? "")
        else {
            throw XCTSkip("This test requires the disposable loopback reference processes.")
        }
        let authority = ReferenceTransport(port: authorityPort)
        let mac = ReferenceTransport(port: macPort)
        _ = try authority.request(.unavailable(false))
        defer { _ = try? authority.request(.unavailable(false)) }
        let app = XCUIApplication()
        app.launchArguments = [
            "--capd-synthetic-sync", "--capd-reference-port", String(authorityPort),
            "--capd-sync-poll-seconds", "1",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        let suffix = String(UUID().uuidString.prefix(6))
        let title = "Automatic annotation \(suffix)"
        app.buttons["captureButton"].tap()
        app.segmentedControls.buttons["Text"].tap()
        enter("Synthetic annotation source \(suffix)", in: app.textFields["sourceInput"])
        enter(title, in: app.textFields["titleInput"])
        enter("Initial annotation", in: app.textFields["noteInput"])
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        try awaitRemote { try authority.baseline().captures.contains { $0.source.title == title } }
        let record = try XCTUnwrap(
            authority.baseline().captures.first(where: { $0.source.title == title }))
        app.staticTexts[title].tap()
        app.buttons["editCapture"].tap()
        replace("Automatically delivered annotation", in: app.textFields["editNoteInput"])
        enter("manual-bird", in: app.textFields["editTagsInput"])
        app.buttons["saveAnnotation"].tap()
        try awaitRemote {
            let current = try authority.baseline().captures.first(where: { $0.id == record.id })
            return current?.note == "Automatically delivered annotation"
                && current?.manualTags == ["manual-bird"]
        }
        _ = try mac.request(.fixturePull)
        XCTAssertEqual(
            try macCaptures(mac).first(where: { $0.id == record.id })?.note,
            "Automatically delivered annotation")
        screenshot("Annotation delivered automatically")

        app.buttons["editCapture"].tap()
        replace("Phone concurrent draft", in: app.textFields["editNoteInput"])
        app.buttons["dismissAnnotationKeyboard"].tap()
        _ = try mac.request(
            .fixtureEdit(
                record.id,
                CaptureEdit(
                    note: NoteEdit("Mac concurrent note"),
                    generated: GeneratedContent(
                        body: "Synthetic generated river source", tags: ["river-generated"]))))
        _ = try mac.request(.fixtureSync)
        try awaitRemote {
            try authority.baseline().captures.first(where: { $0.id == record.id })?.note
                == "Mac concurrent note"
        }
        // Let the one-second foreground pull run while this editor retains its observed revision.
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertEqual(app.textFields["editNoteInput"].value as? String, "Phone concurrent draft")
        app.buttons["saveAnnotation"].tap()
        try awaitRemote {
            let current = try authority.baseline().captures.first(where: { $0.id == record.id })
            return current?.noteConflicts.count == 2
        }
        XCTAssertTrue(
            app.staticTexts["Phone concurrent draft"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mac concurrent note"].firstMatch.exists)
        screenshot("Automatic delivery preserves concurrent note variants")
        app.buttons["editCapture"].tap()
        replace("Combined phone and Mac note", in: app.textFields["editNoteInput"])
        app.buttons["dismissAnnotationKeyboard"].tap()
        let resolution = app.switches["resolveNoteVariants"]
        XCTAssertTrue(resolution.waitForExistence(timeout: 5))
        if !resolution.isHittable { app.swipeUp() }
        resolution.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(resolution.value as? String, "1")
        app.buttons["saveAnnotation"].tap()
        try awaitRemote {
            let current = try authority.baseline().captures.first(where: { $0.id == record.id })
            return current?.note == "Combined phone and Mac note"
                && current?.noteConflicts.isEmpty == true
        }
        _ = try mac.request(.fixturePull)
        let resolved = try XCTUnwrap(macCaptures(mac).first(where: { $0.id == record.id }))
        XCTAssertEqual(resolved.note, "Combined phone and Mac note")
        XCTAssertTrue(resolved.noteConflicts.isEmpty)
        XCTAssertEqual(resolved.manualTags, ["manual-bird"])
        XCTAssertEqual(resolved.generated.tags, ["river-generated"])
        screenshot("Automatically delivered explicit resolution")
        app.buttons["deleteCapture"].tap()
        let confirmation = app.sheets["Delete this saved source?"].buttons["confirmDelete"]
            .firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        try awaitRemote {
            try authority.baseline().captures.first(where: { $0.id == record.id })?.deleted == true
        }
        _ = try mac.request(.fixturePull)
        XCTAssertEqual(try macCaptures(mac).first(where: { $0.id == record.id })?.deleted, true)
        XCTAssertFalse(app.alerts["Library message"].exists)
    }

    private func awaitRemote(_ condition: () throws -> Bool) throws {
        for _ in 0..<60 {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("Automatic reference state did not arrive")
    }

    private func macCaptures(_ transport: ReferenceTransport) throws -> [SharedCapture] {
        guard case .captures(let captures) = try transport.request(.fixtureCaptures) else {
            throw SyncError.invalidOperation
        }
        return captures
    }

    @MainActor
    private func enter(_ text: String, in field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    @MainActor
    private func replace(_ text: String, in field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.press(forDuration: 1.1)
        let app = XCUIApplication()
        let selectAll = app.menuItems["Select All"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
        selectAll.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
