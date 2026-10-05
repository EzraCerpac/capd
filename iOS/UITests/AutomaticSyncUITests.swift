import CapdSync
import XCTest

final class AutomaticSyncUITests: XCTestCase {
    @MainActor
    func testOriginalMacMetadataAppearsOnSavedCapture() throws {
        continueAfterFailure = false
        guard let port = UInt16(ProcessInfo.processInfo.environment["CAPD_REFERENCE_PORT"] ?? "")
        else {
            throw XCTSkip("Requires an owned synthetic reference authority.")
        }
        let authority = ReferenceTransport(port: port)
        let title = "Original Mac metadata \(UUID().uuidString.prefix(6))"
        let record = SharedCapture(
            source: CaptureSource(kind: .text, title: title, selection: "Synthetic Mac capture"),
            createdAt: Date(timeIntervalSinceReferenceDate: 123_456_789.12345679),
            metadata: CaptureMetadata(
                updatedAt: Date(timeIntervalSinceReferenceDate: 123_456_791.98765432),
                lastSeenAt: Date(timeIntervalSinceReferenceDate: 123_456_793.00000012),
                reminderAt: Date(timeIntervalSinceReferenceDate: 123_456_799.23456789),
                sourceAppBundleID: "test.synthetic-mac-app"))
        _ = try authority.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: record.id, baseRevision: 0,
                mutation: .create(record)))
        let app = XCUIApplication()
        app.launchArguments = ["--capd-synthetic-sync", "--capd-reference-port", String(port)]
        app.launch()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        app.staticTexts[title].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["captureUpdatedAt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["captureLastSeenAt"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["captureReminderAt"].exists)
        let application = app.descendants(matching: .any)["captureSourceApp"]
        XCTAssertTrue(application.exists)
        screenshot("Original Mac timestamps reminder and source application")
        XCTAssertTrue(
            application.label.contains("test.synthetic-mac-app"), application.debugDescription)
        app.terminate()
    }

    @MainActor
    func testSyntheticSetupIsDisposableAndLiveConnectionRemainsDisabled() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--capd-synthetic-enrollment"]
        app.launch()
        XCTAssertTrue(app.buttons["deviceSyncSettings"].waitForExistence(timeout: 10))
        app.buttons["deviceSyncSettings"].tap()
        XCTAssertTrue(app.buttons["prepareDeviceConnection"].waitForExistence(timeout: 5))
        app.buttons["prepareDeviceConnection"].tap()
        let connect = app.buttons["connectDeviceDisabled"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(connect.isEnabled)
        app.buttons["fillSyntheticSetup"].tap()
        app.buttons["checkSyntheticSetup"].tap()
        let result = app.staticTexts["syntheticSetupResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("1 queued capture survived reopening"))
        XCTAssertFalse(connect.isEnabled)
        app.swipeUp()
        XCTAssertTrue(result.isHittable)
        screenshot("Synthetic setup with live enrollment disabled")
        app.terminate()
    }

    @MainActor
    func testAutomaticDeliveryOfflineReopenLostAckAndIdleRemoteArrival() throws {
        continueAfterFailure = false
        guard
            let authorityPort = UInt16(
                ProcessInfo.processInfo.environment["CAPD_REFERENCE_PORT"] ?? ""),
            let macPort = UInt16(ProcessInfo.processInfo.environment["CAPD_MAC_FIXTURE_PORT"] ?? "")
        else {
            throw XCTSkip("Requires the owned synthetic reference processes.")
        }
        let authority = ReferenceTransport(port: authorityPort)
        let mac = ReferenceTransport(port: macPort)
        _ = try authority.request(.unavailable(true))
        defer { _ = try? authority.request(.unavailable(false)) }
        let app = XCUIApplication()
        app.launchArguments = [
            "--capd-synthetic-sync", "--capd-reference-port", String(authorityPort),
            "--capd-sync-poll-seconds", "1",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["captureButton"].waitForExistence(timeout: 10))
        let suffix = String(UUID().uuidString.prefix(6))
        let title = "Automatic river note \(suffix)"
        app.buttons["captureButton"].tap()
        app.segmentedControls.buttons["Text"].tap()
        enter(
            "Synthetic automatically shared source \(suffix)", field: app.textFields["sourceInput"])
        enter(title, field: app.textFields["titleInput"])
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Library message"].exists)
        screenshot("Local save during ordinary offline state")
        app.terminate()
        _ = try authority.request(.unavailable(false))
        let before = try authority.baseline().cursor
        _ = try authority.request(.dropNextAcknowledgement)
        app.launch()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        try awaitRemote {
            try authority.baseline().captures.first(where: { $0.source.title == title }) != nil
        }
        let record = try XCTUnwrap(
            authority.baseline().captures.first(where: { $0.source.title == title }))
        let feed = try authority.changes(after: before, limit: 100)
        let origin = try XCTUnwrap(feed.changes.first(where: { $0.capture.id == record.id }))
        try awaitRemote {
            let baseline = try authority.baseline()
            return baseline.deviceSequences[origin.deviceID] == origin.sequence
                && baseline.captures.first(where: { $0.id == record.id })?.seenCount == 1
        }
        XCTAssertFalse(app.alerts["Library message"].exists)
        _ = try mac.request(.fixturePull)
        guard case .captures(let accepted) = try mac.request(.fixtureCaptures) else {
            throw SyncError.invalidOperation
        }
        XCTAssertEqual(accepted.first(where: { $0.id == record.id })?.source.title, title)

        let incoming = SharedCapture(
            source: CaptureSource(
                kind: .text,
                contentHash: CaptureFingerprint.contentHash(
                    for: Data("idle remote \(suffix)".utf8)),
                title: "Remote arrived automatically \(suffix)", selection: "Synthetic idle arrival"
            ))
        _ = try mac.request(.fixtureCreate(incoming))
        _ = try mac.request(.fixtureSync)
        XCTAssertTrue(app.staticTexts[incoming.source.title!].waitForExistence(timeout: 10))
        XCTAssertEqual(
            try authority.baseline().captures.first(where: { $0.id == record.id })?.seenCount, 1)
        XCTAssertEqual(
            try authority.changes(after: before, limit: 100).changes.filter {
                $0.capture.id == record.id
            }.count, 1)
        XCTAssertFalse(app.alerts["Library message"].exists)
        screenshot("Other device arrives while app remains open")
    }

    @MainActor
    private func enter(_ text: String, field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
    }

    private func awaitRemote(_ condition: () throws -> Bool) throws {
        for _ in 0..<60 {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("Automatic reference state did not arrive")
    }

    @MainActor
    private func screenshot(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
