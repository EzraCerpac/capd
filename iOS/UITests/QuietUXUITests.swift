import CapdSync
import XCTest

final class QuietUXUITests: XCTestCase {
    @MainActor
    func testQuietLocalCaptureAndConnectionDetails() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        if app.buttons["dismissSyncIntroduction"].waitForExistence(timeout: 3) {
            screenshot("One-time local library introduction")
            app.buttons["dismissSyncIntroduction"].tap()
        }
        assertQuietLibrary(app)
        if !find(app.staticTexts["Kingfisher field note"], in: app) {
            app.buttons["captureButton"].tap()
            app.segmentedControls.buttons["Text"].tap()
            enter(
                "A synthetic source describing marsh habitat and field observations.",
                field: app.textFields["sourceInput"])
            enter("Kingfisher field note", field: app.textFields["titleInput"])
            enter("Check the marsh again in spring.", field: app.textFields["noteInput"])
            app.navigationBars["Capture"].buttons["Save"].tap()
            XCTAssertTrue(find(app.staticTexts["Kingfisher field note"], in: app))
            app.staticTexts["Kingfisher field note"].tap()
            app.buttons["editCapture"].tap()
            enter("fieldwork birds", field: app.textFields["editTagsInput"])
            app.buttons["dismissAnnotationKeyboard"].tap()
            app.buttons["saveAnnotation"].tap()
            XCTAssertTrue(app.buttons["editCapture"].waitForExistence(timeout: 5))
            app.navigationBars.buttons["BackButton"].tap()
            app.buttons["captureButton"].tap()
            enter(
                "https://example.invalid/research/marsh-birds", field: app.textFields["sourceInput"]
            )
            enter("Marsh bird survey", field: app.textFields["titleInput"])
            app.navigationBars["Capture"].buttons["Save"].tap()
            XCTAssertTrue(find(app.staticTexts["Marsh bird survey"], in: app))
        }
        assertQuietLibrary(app)
        screenshot("Quiet saved library")
        app.staticTexts["Kingfisher field note"].tap()
        XCTAssertTrue(app.buttons["editCapture"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Available on this iPhone"].exists)
        XCTAssertFalse(app.staticTexts["Synced"].exists)
        screenshot("Local availability detail")
        app.buttons["editCapture"].tap()
        XCTAssertTrue(app.textFields["editTagsInput"].waitForExistence(timeout: 5))
        screenshot("Quiet annotation")
        app.navigationBars["Annotation"].buttons["Cancel"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["deviceSyncSettings"].tap()
        XCTAssertTrue(
            app.staticTexts["Captures save here immediately and stay available offline."]
                .waitForExistence(timeout: 5))
        XCTAssertTrue(find(app.staticTexts["Not connected"], in: app))
        XCTAssertFalse(app.buttons["retryDeviceSync"].exists)
        screenshot("Honest unconfigured device settings")
        app.buttons["closeSyncSettings"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["dismissSyncIntroduction"].exists)
        XCTAssertTrue(find(app.staticTexts["Kingfisher field note"], in: app))
        assertQuietLibrary(app)
        app.terminate()
    }

    @MainActor
    func testClosedAppShareRemainsQuiet() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        if app.buttons["dismissSyncIntroduction"].exists {
            app.buttons["dismissSyncIntroduction"].tap()
        }
        app.terminate()
        let host = XCUIApplication(bundleIdentifier: "dev.jxd.capd.iphone.fixture")
        host.launch()
        host.buttons["Share fixture text"].tap()
        XCTAssertTrue(host.cells["capd"].firstMatch.waitForExistence(timeout: 10))
        host.cells["capd"].firstMatch.tap()
        let save = host.navigationBars["Save to capd"].buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertFalse(host.staticTexts["Save locally now. Sync is not configured."].exists)
        screenshot("Quiet closed-app share extension")
        save.tap()
        XCTAssertTrue(host.navigationBars["Save to capd"].waitForNonExistence(timeout: 10))
        host.terminate()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Synthetic external source: marsh bird survey."].firstMatch
                .waitForExistence(timeout: 10))
        assertQuietLibrary(app)
        app.terminate()
    }

    @MainActor
    func testPersistentAttentionAndRecoveryInSettings() throws {
        continueAfterFailure = false
        guard let port = UInt16(ProcessInfo.processInfo.environment["CAPD_REFERENCE_PORT"] ?? "")
        else {
            throw XCTSkip("Requires the owned synthetic reference process.")
        }
        let authority = ReferenceTransport(port: port)
        _ = try authority.request(.unavailable(true))
        defer { _ = try? authority.request(.unavailable(false)) }
        let app = XCUIApplication()
        app.launchArguments = [
            "--capd-synthetic-sync", "--capd-reference-port", String(port),
            "--capd-sync-poll-seconds", "1",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        app.buttons["captureButton"].tap()
        app.segmentedControls.buttons["Text"].tap()
        enter(
            "Synthetic retained source during a connection failure.",
            field: app.textFields["sourceInput"])
        let title = "Retained river source \(UUID().uuidString.prefix(4))"
        enter(title, field: app.textFields["titleInput"])
        app.navigationBars["Capture"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Library message"].exists)
        XCTAssertTrue(app.buttons["syncAttention"].waitForExistence(timeout: 15))
        screenshot("Persistent connection attention in library")
        app.buttons["syncAttention"].tap()
        XCTAssertTrue(app.buttons["retryDeviceSync"].waitForExistence(timeout: 5))
        screenshot("Persistent connection details")
        _ = try authority.request(.unavailable(false))
        app.buttons["retryDeviceSync"].tap()
        XCTAssertTrue(app.staticTexts["Automatic device updates"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["retryDeviceSync"].exists)
        screenshot("Recovered automatic device settings")
        app.buttons["closeSyncSettings"].tap()
        XCTAssertFalse(app.buttons["syncAttention"].exists)
        XCTAssertFalse(app.alerts["Library message"].exists)
        app.terminate()
    }

    @MainActor
    private func assertQuietLibrary(_ app: XCUIApplication) {
        XCTAssertFalse(app.buttons["syncButton"].exists)
        XCTAssertFalse(app.buttons["refreshButton"].exists)
        XCTAssertFalse(app.staticTexts["pendingStatus"].exists)
        XCTAssertFalse(app.staticTexts["Pending"].exists)
        XCTAssertFalse(app.buttons["syncAttention"].exists)
        XCTAssertFalse(app.alerts["Library message"].exists)
    }

    @MainActor
    private func find(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }

    @MainActor
    private func enter(_ text: String, field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
