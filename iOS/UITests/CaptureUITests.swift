import CapdSync
import XCTest

final class CaptureUITests: XCTestCase {
    @MainActor
    func testCaptureSearchShareAndPersistence() throws {
        let app = XCUIApplication()
        continueAfterFailure = false
        let captureTitle = "Kingfisher field note \(UUID().uuidString.prefix(4))"
        let sourceText = "Synthetic offline source: kingfisher habitat. \(captureTitle)"
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        app.buttons["captureButton"].tap()
        app.segmentedControls.buttons["Text"].tap()
        let source = app.textFields["sourceInput"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        source.typeText(sourceText)
        let title = app.textFields["titleInput"]
        title.tap()
        title.typeText(captureTitle)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[captureTitle].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts[captureTitle].waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("habitat")
        XCTAssertTrue(app.staticTexts[captureTitle].exists)
        app.staticTexts[captureTitle].tap()
        XCTAssertTrue(
            app.staticTexts[sourceText].waitForExistence(
                timeout: 5))
        attachScreenshot("Source detail")
        app.buttons["shareCapture"].tap()
        let extensionCell = app.cells["capd"].firstMatch
        XCTAssertTrue(extensionCell.waitForExistence(timeout: 5), app.debugDescription)
        extensionCell.tap()
        let save = app.navigationBars["Save to capd"].buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot("Share extension")
        save.tap()
        let completed = app.navigationBars["Save to capd"].waitForNonExistence(timeout: 10)
        if !completed { attachScreenshot("Self share did not complete") }
        XCTAssertTrue(completed, app.debugDescription)
        app.terminate()
        app.launch()
        XCTAssertTrue(
            app.staticTexts[sourceText].firstMatch
                .waitForExistence(
                    timeout: 10))
        attachScreenshot("Local library")
    }

    @MainActor
    func testExternalShareWhileMainAppIsClosed() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let sourceText = "Synthetic external source: marsh bird survey."
        let authority = UInt16(ProcessInfo.processInfo.environment["CAPD_REFERENCE_PORT"] ?? "")
            .map { ReferenceTransport(port: $0) }
        let previousSeen =
            try authority?.baseline().captures.first {
                $0.source.selection == sourceText
            }?.seenCount ?? 0
        if let authority {
            _ = try authority.request(.unavailable(true))
            app.launchArguments = [
                "--capd-synthetic-sync", "--capd-reference-port", String(authority.port),
            ]
        }
        defer { _ = try? authority?.request(.unavailable(false)) }
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        app.terminate()

        let host = XCUIApplication(bundleIdentifier: "dev.jxd.capd.iphone.fixture")
        host.launch()
        host.buttons["Share fixture text"].tap()
        let cell = host.cells["capd"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), host.debugDescription)
        cell.tap()
        let save = host.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), host.debugDescription)
        XCTAssertTrue(save.isEnabled)
        attachScreenshot("External share with capd closed")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        XCTAssertTrue(host.buttons["Share fixture text"].waitForExistence(timeout: 10))
        host.terminate()
        _ = try authority?.request(.unavailable(false))
        app.launch()
        XCTAssertTrue(
            app.staticTexts[sourceText].firstMatch
                .waitForExistence(timeout: 10))
        if let authority {
            for _ in 0..<60 {
                if try authority.baseline().captures.first(where: {
                    $0.source.selection == sourceText
                })?.seenCount == previousSeen + 1 {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            XCTAssertEqual(
                try authority.baseline().captures.first(where: {
                    $0.source.selection == sourceText
                })?.seenCount, previousSeen + 1)
        }
        attachScreenshot("Shared source in local library")
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
