import CapdSync
import Foundation
import Testing

@testable import CapdMobile

@Test func preparedAdapterCannotActivateBeforeMigrationAcceptance() throws {
    let enrollment = try SyncEnrollment(
        endpoint: URL(string: "https://sync.example.invalid/v1/sync")!,
        binding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()), deviceID: UUID())
    let credentials = MemorySyncCredentialStore()
    #expect(throws: SyncConnectionError.enrollmentDisabled) {
        try EnrolledSyncAdapter(enrollment: enrollment, credentials: credentials)
    }
    #expect(throws: SyncConnectionError.credentialUnavailable) {
        try credentials.read(for: enrollment)
    }
}

@Test func asyncMobileInjectionRefusesUnboundLibraryBeforeSendingOrReadingCredentials() async throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-async-mobile-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MobileStore(url: root.appendingPathComponent("mobile.sqlite"))
    try store.save(
        MobileCapture(kind: .text, title: "Synthetic retained capture", selection: "Kept locally"))
    let pending = try store.pending()
    let coordinator = MobileSyncCoordinator(store: store, adapter: UnboundAsyncTestAdapter())
    await #expect(throws: SyncBindingError.bindingRequired) { try await coordinator.sync() }
    #expect(try store.pending() == pending)
    #expect(try store.search().first?.title == "Synthetic retained capture")
}

private struct UnboundAsyncTestAdapter: MobileSyncAdapter {
    func availability() async -> SyncAvailability { .ready }
    func transport() async -> (any SyncTransport)? { nil }
    func asyncConnection() async -> MobileAsyncSyncConnection? {
        MobileAsyncSyncConnection(
            transport: NoSendTransport(),
            credential: {
                Issue.record("Unbound mobile library must not read credentials")
                throw SyncConnectionError.credentialUnavailable
            })
    }
}

private struct NoSendTransport: AsyncSyncTransport {
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let deviceID = UUID()
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        Issue.record("Unbound mobile library must not send requests")
        throw SyncHTTPError.unavailable
    }
}
