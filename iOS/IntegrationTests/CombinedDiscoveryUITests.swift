import XCTest

final class CombinedDiscoveryUITests: XCTestCase {
    @MainActor
    func testSyntheticCitationOpensActualSavedCapture() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--capd-synthetic-citation"]
        app.launch()
        let fixtureTitle = "Synthetic citation \(UUID().uuidString.prefix(4))"
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        app.buttons["captureButton"].tap()
        app.segmentedControls.buttons["Text"].tap()
        app.textFields["sourceInput"].tap()
        app.textFields["sourceInput"].typeText(
            "An orchid needs indirect light. This is synthetic gardening evidence. \(fixtureTitle)")
        app.textFields["titleInput"].tap()
        app.textFields["titleInput"].typeText(fixtureTitle)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[fixtureTitle].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["askCapButton"].waitForExistence(timeout: 10))
        app.buttons["askCapButton"].tap()
        let question = app.descendants(matching: .any)["libraryQuestion"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap()
        question.typeText("What light does an orchid need?")
        app.buttons["dismissQuestionKeyboard"].tap()
        app.buttons["askLibraryQuestion"].tap()
        let citation = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "answerSource-")
        ).firstMatch
        for _ in 0..<5 {
            if citation.exists && citation.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(citation.waitForExistence(timeout: 5), app.debugDescription)
        let title = String(citation.label.split(separator: "]", maxSplits: 1).last ?? "")
            .trimmingCharacters(in: .whitespaces)
        attach(app, name: "Synthetic fixture citation with real local retrieval")
        citation.tap()
        XCTAssertTrue(app.buttons["editCapture"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].exists)
        attach(app, name: "Synthetic fixture citation opens actual saved source")
    }

    @MainActor
    func testColdSearchRouteAndActualLocalAnswerAttempt() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let title = "Synthetic orchid \(UUID().uuidString.prefix(4))"
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        app.buttons["captureButton"].tap()
        app.segmentedControls.buttons["Text"].tap()
        app.textFields["sourceInput"].tap()
        app.textFields["sourceInput"].typeText(
            "An orchid needs indirect light. This is synthetic gardening evidence. \(title)")
        app.textFields["titleInput"].tap()
        app.textFields["titleInput"].typeText(title)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.buttons["deviceSyncSettings"].tap()
        let consent = app.switches["systemSearchEnabled"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        if consent.value as? String != "1" {
            consent.switches.firstMatch.exists ? consent.switches.firstMatch.tap() : consent.tap()
        }
        XCTAssertTrue(
            app.staticTexts["System search is ready"].waitForExistence(timeout: 60),
            app.debugDescription)
        app.buttons["closeSyncSettings"].tap()
        app.terminate()

        let fixture = XCUIApplication(bundleIdentifier: "dev.jxd.capd.iphone.fixture")
        fixture.launchEnvironment["CAPD_FIXTURE_ROUTE"] = "capd://find?q=orchid"
        fixture.launch()
        fixture.buttons["Open synthetic capture route"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitUntil { app.searchFields.firstMatch.value as? String == "orchid" },
            app.debugDescription)
        XCTAssertTrue(app.staticTexts[title].exists)
        app.buttons["askCapButton"].tap()
        let question = app.descendants(matching: .any)["libraryQuestion"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 5))
        question.tap()
        question.typeText("What light does an orchid need?")
        app.buttons["dismissQuestionKeyboard"].tap()
        if app.buttons["checkAnswerAvailability"].exists {
            attach(app, name: "Actual local model unavailable")
            XCTAssertFalse(app.buttons["askLibraryQuestion"].isEnabled)
        } else {
            app.buttons["askLibraryQuestion"].tap()
            let completed = waitUntil(timeout: 90) {
                app.buttons["askLibraryQuestion"].exists
                    || app.descendants(matching: .any)["libraryAnswerMessage"].firstMatch.exists
            }
            if !completed {
                attach(app, name: "Actual local generation timed out")
                app.buttons["Cancel"].tap()
            } else if app.buttons["answerSource-1"].exists {
                attach(app, name: "Actual locally generated cited answer")
                app.buttons["answerSource-1"].tap()
                XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["editCapture"].exists)
                attach(app, name: "Actual answer citation opens saved source")
                app.navigationBars.buttons.firstMatch.tap()
            } else {
                attach(app, name: "Actual local generation reported no answer")
                XCTAssertTrue(
                    app.descendants(matching: .any)["libraryAnswerMessage"].firstMatch.exists,
                    app.debugDescription)
            }
        }
        app.buttons["Done"].tap()
        app.buttons["deviceSyncSettings"].tap()
        let disable = app.switches["systemSearchEnabled"]
        if disable.value as? String == "1" {
            disable.switches.firstMatch.exists ? disable.switches.firstMatch.tap() : disable.tap()
        }
        XCTAssertTrue(
            app.staticTexts["System search is off"].waitForExistence(timeout: 15),
            app.debugDescription)
        app.buttons["closeSyncSettings"].tap()
        fixture.terminate()
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in predicate() }, object: nil)
            ],
            timeout: timeout) == .completed
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
