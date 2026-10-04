import XCTest

final class AnswersUITests: XCTestCase {
    @MainActor
    func testAskScreenUsesCurrentModelAvailabilityAndPreservesCapture() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let title = "Synthetic answer source \(UUID().uuidString.prefix(4))"
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        app.buttons["captureButton"].tap()
        app.segmentedControls.buttons["Text"].tap()
        let source = app.textFields["sourceInput"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        source.typeText("Synthetic source: an orchid needs indirect light. \(title)")
        app.textFields["titleInput"].tap()
        app.textFields["titleInput"].typeText(title)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.buttons["askCapButton"].tap()
        let question = app.descendants(matching: .any)["libraryQuestion"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["askLibraryQuestion"].isEnabled)
        let unavailable = app.buttons["checkAnswerAvailability"].exists
        question.tap()
        question.typeText("What light does an orchid need?")
        if unavailable {
            XCTAssertFalse(app.buttons["askLibraryQuestion"].isEnabled)
            app.buttons["checkAnswerAvailability"].tap()
            XCTAssertFalse(app.buttons["askLibraryQuestion"].isEnabled)
        } else {
            // Simulators may expose the host model. Exercise the ready UI without
            // starting generation; actual quality/availability remain a device check.
            XCTAssertTrue(app.buttons["askLibraryQuestion"].isEnabled)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "On-device answers availability"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }
}
