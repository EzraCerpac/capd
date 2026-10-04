import CapdSync
import Foundation
import Testing

@testable import CapdMobile

@Test func metadataReadsRespectTransitionLeaseAndRetiredLibraryGeneration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try MobileLibrarySession.open(root: root, role: .app)
    try session.store.save(CaptureInput.make(text: "Synthetic fenced metadata", isLink: false))
    let revision = try session.store.libraryRevision()
    #expect(revision.pendingChanges == 1)
    #expect(
        try session.store.syncSnapshot(previousRevision: nil, previousConflictCount: 0).revision
            == revision)
    do {
        let lease = try MobileLibraryLease(root: root, exclusive: true)
        #expect(throws: MobileActivationError.transitionBusy) {
            try session.store.libraryRevision()
        }
        #expect(throws: MobileActivationError.transitionBusy) {
            try session.store.syncSnapshot(previousRevision: revision, previousConflictCount: 0)
        }
        withExtendedLifetime(lease) {}
    }
    #expect(try session.store.libraryRevision() == revision)
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let enrollment = try SyncEnrollment(
        endpoint: URL(string: "https://sync.example.invalid/v1/sync")!, binding: binding,
        deviceID: UUID())
    try MobileLibraryAccess.publish(
        MobileLibraryConfiguration(generation: UUID(), enrollment: enrollment), in: root)
    #expect(throws: MobileActivationError.sessionReplaced) { try session.store.libraryRevision() }
    #expect(throws: MobileActivationError.sessionReplaced) {
        try session.store.syncSnapshot(previousRevision: revision, previousConflictCount: 0)
    }
}
