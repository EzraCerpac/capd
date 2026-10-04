import XCTest

final class LibraryConnectionUITests: XCTestCase {
    @MainActor
    func testStartupPreparationDrainsReadersBeforeTakingExclusiveLease() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("Synthetic preparation requires an owned simulator.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard let owned = environment["CAPD_ACTIVATION_OWNED_SIMULATOR"],
            owned == environment["SIMULATOR_UDID"]
        else { throw XCTSkip("Provide the exact disposable simulator UUID.") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--capd-prepare-connection", "https://sync.example.invalid/v1/sync",
            UUID().uuidString, UUID().uuidString,
        ]
        app.launch()
        XCTAssertTrue(app.buttons["deviceSyncSettings"].waitForExistence(timeout: 10))
        app.buttons["deviceSyncSettings"].tap()
        app.buttons["prepareDeviceConnection"].tap()
        let status = app.staticTexts["connectionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(status.label.contains("Backup saved"), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["connectionError"].exists)
        app.terminate()
    }

    @MainActor
    func testBackupPreparationRetainsCaptureAcrossRelaunchAndClosedAppShare() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("Synthetic connection preparation requires an owned simulator.")
        #endif
        let environment = ProcessInfo.processInfo.environment
        guard let owned = environment["CAPD_ACTIVATION_OWNED_SIMULATOR"],
            owned == environment["SIMULATOR_UDID"]
        else {
            throw XCTSkip("Provide the exact disposable simulator UUID for this synthetic test.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        let title = "Synthetic activation orchid \(UUID().uuidString.prefix(5))"
        app.buttons["captureButton"].tap()
        app.segmentedControls.buttons["Text"].tap()
        app.textFields["sourceInput"].tap()
        app.textFields["sourceInput"].typeText(
            "Synthetic backup fixture; no private captures. \(title)")
        app.textFields["titleInput"].tap()
        app.textFields["titleInput"].typeText(title)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        app.buttons["deviceSyncSettings"].tap()
        app.buttons["prepareDeviceConnection"].tap()
        for _ in 0..<6 {
            if app.textFields["connectionAddress"].exists
                && app.textFields["connectionAddress"].isHittable
            {
                break
            }
            app.swipeUp()
        }
        XCTAssertTrue(app.textFields["connectionAddress"].waitForExistence(timeout: 5))
        fill(app.textFields["connectionAddress"], "https://sync.example.invalid/v1/sync")
        fill(app.textFields["connectionServiceID"], UUID().uuidString)
        fill(app.textFields["connectionLibraryID"], UUID().uuidString)
        app.buttons["prepareLibraryBackup"].tap()
        let status = app.staticTexts["connectionStatus"]
        for _ in 0..<5 {
            if status.waitForExistence(timeout: 1) { break }
            app.swipeDown()
        }
        XCTAssertTrue(status.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(status.label.contains("Backup saved"))
        XCTAssertTrue(app.buttons["exportConnectionSnapshot"].waitForExistence(timeout: 10))
        app.buttons["exportConnectionSnapshot"].tap()
        let cancelExport = app.buttons["cancelConnectionExport"]
        XCTAssertTrue(cancelExport.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["On My iPhone"].waitForExistence(timeout: 5))
        cancelExport.tap()
        XCTAssertTrue(app.buttons["exportConnectionSnapshot"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        app.buttons["deviceSyncSettings"].tap()
        app.buttons["prepareDeviceConnection"].tap()
        XCTAssertTrue(app.buttons["exportConnectionSnapshot"].waitForExistence(timeout: 5))
        let connect = app.buttons["activateLibraryConnection"]
        for _ in 0..<3 { app.swipeDown() }
        let generate = app.buttons["generateConnectionCredential"]
        for _ in 0..<14 {
            if generate.exists && generate.isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                .press(
                    forDuration: 0.1,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        XCTAssertTrue(generate.waitForExistence(timeout: 5), app.debugDescription)
        if !generate.isHittable { app.swipeUp() }
        generate.tap()
        let verifier = app.descendants(matching: .any)["connectionCredentialVerifier"].firstMatch
        for _ in 0..<6 {
            if verifier.exists && verifier.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(verifier.waitForExistence(timeout: 5), app.debugDescription)
        app.swipeUp()
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        // A synthetic in-memory credential supplies neither import proof nor a grant.
        XCTAssertFalse(connect.isEnabled)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Retained synthetic backup and guarded connection"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        let host = XCUIApplication(bundleIdentifier: "dev.jxd.capd.iphone.fixture")
        host.launch()
        host.buttons["Share fixture text"].tap()
        let cell = host.cells["capd"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.tap()
        let save = host.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15), host.debugDescription)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        host.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Synthetic external source: marsh bird survey."].firstMatch
                .waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor private func fill(_ field: XCUIElement, _ value: String) {
        field.tap()
        field.typeText(value)
    }
}
