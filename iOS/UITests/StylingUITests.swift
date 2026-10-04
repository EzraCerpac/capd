import XCTest

final class StylingUITests: XCTestCase {
    @MainActor
    func testSyntheticLibraryAndAnnotation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        if !app.staticTexts["Kingfisher field note"].exists {
            app.buttons["captureButton"].tap()
            app.segmentedControls.buttons["Text"].tap()
            enter(
                "A synthetic source describing marsh habitat and field observations.",
                field: app.textFields["sourceInput"])
            enter("Kingfisher field note", field: app.textFields["titleInput"])
            app.navigationBars["Capture"].buttons["Save"].tap()
            XCTAssertTrue(app.staticTexts["Kingfisher field note"].waitForExistence(timeout: 5))
            app.staticTexts["Kingfisher field note"].tap()
            app.buttons["editCapture"].tap()
            enter("fieldwork birds", field: app.textFields["editTagsInput"])
            if app.buttons["dismissAnnotationKeyboard"].exists {
                app.buttons["dismissAnnotationKeyboard"].tap()
            }
            app.buttons["saveAnnotation"].tap()
            XCTAssertTrue(app.buttons["editCapture"].waitForExistence(timeout: 5))
            app.navigationBars.buttons["BackButton"].tap()
            app.buttons["captureButton"].tap()
            enter(
                "https://example.invalid/research/marsh-birds", field: app.textFields["sourceInput"]
            )
            enter("Marsh bird survey", field: app.textFields["titleInput"])
            app.navigationBars["Capture"].buttons["Save"].tap()
            XCTAssertTrue(app.staticTexts["Marsh bird survey"].waitForExistence(timeout: 5))
        }
        screenshot("Styled library")
        app.staticTexts["Kingfisher field note"].tap()
        XCTAssertTrue(app.buttons["editCapture"].waitForExistence(timeout: 5))
        screenshot("Styled source detail")
        app.buttons["editCapture"].tap()
        XCTAssertTrue(app.textFields["editTagsInput"].waitForExistence(timeout: 5))
        screenshot("Styled annotation form")
        app.navigationBars["Annotation"].buttons["Cancel"].tap()
        app.terminate()
    }

    @MainActor
    func testStyledShareExtensionWithMainAppClosed() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        app.terminate()
        let host = XCUIApplication(bundleIdentifier: "dev.jxd.capd.iphone.fixture")
        host.launch()
        host.buttons["Share fixture text"].tap()
        XCTAssertTrue(host.cells["capd"].firstMatch.waitForExistence(timeout: 10))
        host.cells["capd"].firstMatch.tap()
        let save = host.navigationBars["Save to capd"].buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        screenshot("Styled share extension")
        save.tap()
        XCTAssertTrue(host.navigationBars["Save to capd"].waitForNonExistence(timeout: 10))
        host.terminate()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Synthetic external source: marsh bird survey."].firstMatch
                .waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testLongMetadataAndTagsFixture() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        if !app.staticTexts["Long location source"].exists {
            app.buttons["captureButton"].tap()
            app.segmentedControls.buttons["Link"].tap()
            enter(
                "https://example.invalid/research/long-source-location/shorebird-field-observations",
                field: app.textFields["sourceInput"])
            enter("Long location source", field: app.textFields["titleInput"])
            app.navigationBars["Capture"].buttons["Save"].tap()
            XCTAssertTrue(app.staticTexts["Long location source"].waitForExistence(timeout: 5))
            app.staticTexts["Long location source"].tap()
            app.buttons["editCapture"].tap()
            enter(
                "long-fieldwork-observations shorebird-migration-research",
                field: app.textFields["editTagsInput"])
            app.buttons["dismissAnnotationKeyboard"].tap()
            app.buttons["saveAnnotation"].tap()
            XCTAssertTrue(app.buttons["editCapture"].waitForExistence(timeout: 5))
            app.navigationBars.buttons["BackButton"].tap()
        }
        app.swipeUp()
        screenshot("Styled long metadata and tags")
        app.terminate()
    }

    @MainActor
    func testAccessibilityLayout() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        screenshot("Styled accessibility library")
        app.swipeUp()
        screenshot("Styled accessibility long row")
        app.swipeUp()
        screenshot("Styled accessibility scrolled sources")
        let title = app.staticTexts["Long location source"]
        XCTAssertTrue(title.exists)
        title.tap()
        XCTAssertTrue(app.buttons["editCapture"].waitForExistence(timeout: 5))
        app.buttons["editCapture"].tap()
        XCTAssertTrue(app.textFields["editTagsInput"].waitForExistence(timeout: 5))
        screenshot("Styled accessibility annotation")
        app.terminate()
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
