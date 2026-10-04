import XCTest

final class IPadDiscoveryUITests: XCTestCase {
    @MainActor
    func testSyntheticCaptureRotationPersistenceAndColdSearchRoute() throws {
        try requireOwnedIPadSimulator()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let token = "CobaltOtter\(UUID().uuidString.prefix(6))"
        let title = "Synthetic iPad \(token)"
        let source = "Synthetic iPad source text for \(token)."
        defer { disableAndTerminate(app) }
        app.launch()
        try save(app, title: title, source: source)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        attach(app, "iPad portrait saved capture")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { app.frame.width > app.frame.height }, app.debugDescription)
        XCTAssertTrue(app.staticTexts[title].exists)
        attach(app, "iPad landscape saved library")
        app.staticTexts[title].tap()
        XCTAssertTrue(app.buttons["editCapture"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[source].exists)
        attach(app, "iPad landscape detail")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        try consent(app, enabled: true)
        app.terminate()
        let fixture = XCUIApplication(bundleIdentifier: "dev.jxd.capd.iphone.fixture")
        fixture.launchEnvironment["CAPD_FIXTURE_ROUTE"] = "capd://find?q=\(token)"
        fixture.launch()
        XCTAssertTrue(fixture.buttons["Open synthetic capture route"].waitForExistence(timeout: 10))
        fixture.buttons["Open synthetic capture route"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { search.value as? String == token }, app.debugDescription)
        XCTAssertTrue(app.staticTexts[title].exists)
        attach(app, "iPad cold search route resolves saved fixture")
        fixture.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testSystemSpotlightSelectsSyntheticSavedCapture() throws {
        try requireOwnedIPadSimulator()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let token = "IndigoHeron\(UUID().uuidString.prefix(6))"
        let title = "Synthetic iPad \(token)"
        let source = "Synthetic private-index test data for \(token)."
        defer { disableAndTerminate(app) }
        app.launch()
        try save(app, title: title, source: source)
        try consent(app, enabled: true)
        app.terminate()
        let spotlight = try openSpotlight(query: token)
        let result = spotlight.cells[title].firstMatch
        guard result.waitForExistence(timeout: 30) else {
            attach(spotlight, "iPad Spotlight synthetic saved item missing")
            XCTFail(
                "Synthetic saved capture did not appear in system Spotlight. "
                    + spotlight.debugDescription)
            return
        }
        attach(spotlight, "iPad system Spotlight shows synthetic saved capture")
        result.tap()
        XCTAssertTrue(
            app.buttons["editCapture"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts[source].exists)
        attach(app, "iPad Spotlight selection opens actual saved capture detail")
        let tag = "warblermoss"
        app.buttons["editCapture"].tap()
        let tags = app.textFields["editTagsInput"]
        XCTAssertTrue(tags.waitForExistence(timeout: 5))
        tags.tap()
        tags.typeText(tag)
        app.buttons["dismissAnnotationKeyboard"].tap()
        app.buttons["saveAnnotation"].tap()
        XCTAssertTrue(app.buttons["editCapture"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["capd"].tap()
        try consent(app, enabled: true)
        app.terminate()
        let updated = try openSpotlight(query: tag)
        let changedResult = updated.cells[title].firstMatch
        XCTAssertTrue(changedResult.waitForExistence(timeout: 30), updated.debugDescription)
        attach(updated, "iPad Spotlight finds updated manual tag")
        changedResult.tap()
        XCTAssertTrue(app.buttons["deleteCapture"].waitForExistence(timeout: 10))
        app.buttons["deleteCapture"].tap()
        let deletion = app.buttons["confirmDelete"].firstMatch
        XCTAssertTrue(deletion.waitForExistence(timeout: 5), app.debugDescription)
        deletion.tap()
        XCTAssertTrue(app.buttons["deviceSyncSettings"].waitForExistence(timeout: 10))
        try consent(app, enabled: true)
        app.terminate()
        let removed = try openSpotlight(query: tag)
        XCTAssertTrue(
            removed.cells[title].firstMatch.waitForNonExistence(timeout: 20),
            removed.debugDescription)
        attach(removed, "iPad Spotlight removes deleted saved capture")
    }

    @MainActor
    func testExternalShareOnIPad() throws {
        try requireOwnedIPadSimulator()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        app.terminate()
        let host = XCUIApplication(bundleIdentifier: "dev.jxd.capd.iphone.fixture")
        defer {
            host.terminate()
            disableAndTerminate(app)
        }
        host.launch()
        host.buttons["Share fixture text"].tap()
        let cell = host.cells["capd"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), host.debugDescription)
        attach(host, "iPad external share before selection")
        let icon = cell.images["activityImageView"].firstMatch
        XCTAssertTrue(icon.exists, host.debugDescription)
        icon.tap()
        let save = host.buttons["Save"].firstMatch
        guard save.waitForExistence(timeout: 15) else {
            attach(host, "iPad external share after icon selection")
            XCTFail("Share extension Save view did not open. " + host.debugDescription)
            return
        }
        XCTAssertTrue(save.isEnabled)
        attach(host, "iPad external share extension")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        host.terminate()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Synthetic external source: marsh bird survey."].firstMatch
                .waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "iPad external share saved source")
    }

    @MainActor
    private func openSpotlight(query: String) throws -> XCUIApplication {
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Search"].exists {
            springboard.buttons["Search"].tap()
        } else {
            let start = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            let end = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")
        let search = spotlight.textFields["SpotlightSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), spotlight.debugDescription)
        search.tap()
        if search.buttons["Clear text"].exists { search.buttons["Clear text"].tap() }
        search.typeText(query)
        XCTAssertEqual(search.value as? String, query)
        return spotlight
    }

    private func requireOwnedIPadSimulator() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let owned = environment["CAPD_IPAD_OWNED_SIMULATOR"],
            environment["SIMULATOR_UDID"] == owned,
            environment["SIMULATOR_MODEL_IDENTIFIER"]?.hasPrefix("iPad") == true
        else {
            throw XCTSkip(
                "Requires an explicitly selected, newly created synthetic iPad simulator.")
        }
    }

    @MainActor
    private func save(_ app: XCUIApplication, title: String, source: String) throws {
        XCTAssertTrue(
            app.buttons["captureButton"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["captureButton"].tap()
        app.segmentedControls.buttons["Text"].tap()
        let input = app.descendants(matching: .any)["sourceInput"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(source)
        let titleInput = app.textFields["titleInput"]
        titleInput.tap()
        titleInput.typeText(title)
        app.navigationBars["Capture"].buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }

    @MainActor
    private func consent(_ app: XCUIApplication, enabled: Bool) throws {
        XCTAssertTrue(app.buttons["deviceSyncSettings"].waitForExistence(timeout: 10))
        app.buttons["deviceSyncSettings"].tap()
        let toggle = app.switches["systemSearchEnabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String == "1") != enabled {
            toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        }
        let status = enabled ? "System search is ready" : "System search is off"
        XCTAssertTrue(app.staticTexts[status].waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["closeSyncSettings"].tap()
    }

    @MainActor
    private func disableAndTerminate(_ app: XCUIApplication) {
        app.terminate()
        app.launch()
        if app.buttons["deviceSyncSettings"].waitForExistence(timeout: 10) {
            try? consent(app, enabled: false)
        }
        app.terminate()
    }

    @MainActor
    private func waitUntil(_ predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in predicate() }, object: nil)
            ], timeout: 10) == .completed
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
