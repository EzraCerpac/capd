import CapdSync
import Foundation
import Testing

@testable import CapdMobile

@Test(arguments: [false, true])
func expiredBaselineRetriesLostAcknowledgementWithoutChangingPullOnly(pullOnly: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(url: root.appendingPathComponent("mobile.sqlite"))
    let server = try SyncServer(
        databaseURL: root.appendingPathComponent("authority.sqlite"),
        blobDirectory: root.appendingPathComponent("authority-assets"))
    let capture = try CaptureInput.make(text: "Lost response before feed expiration", isLink: false)
    try store.save(capture)
    let pending = try store.pending()
    let receipt = try server.apply(#require(pending.first))
    try server.expireFeed(through: server.baseline().cursor)
    let coordinator = MobileSyncCoordinator(
        store: store, adapter: RecoveryCollisionAdapter(server: server))
    if pullOnly {
        await #expect(throws: SyncError.recoverySequenceCollision) {
            try await coordinator.refresh()
        }
        #expect(try store.pending() == pending)
        #expect(try store.capture(id: capture.id)?.revision == 0)
    } else {
        #expect(try await coordinator.sync() == .sent(1, rejected: 0))
        #expect(try store.pending().isEmpty)
        #expect(try store.capture(id: capture.id)?.revision == receipt.capture?.revision)
    }
    #expect(try server.apply(#require(pending.first)) == receipt)
    #expect(try server.baseline().captures.count == 1)
    #expect(try server.baseline().captures.first?.seenCount == 1)
}

private struct RecoveryCollisionAdapter: MobileSyncAdapter {
    let server: SyncServer
    func availability() async -> SyncAvailability { .ready }
    func transport() async -> (any SyncTransport)? { server }
}
