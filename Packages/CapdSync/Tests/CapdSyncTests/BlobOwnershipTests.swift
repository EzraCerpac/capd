import Foundation
import Testing

@testable import CapdSync

@Suite("Client blob library ownership")
struct BlobOwnershipTests {
    @Test func swappedBoundDirectoriesRejectWithoutLosingPendingAssets() throws {
        let fixture = BlobOwnershipFixture()
        defer { fixture.clean() }
        let a = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let b = SyncLibraryBinding(libraryID: UUID(), serviceID: a.serviceID)
        let first = try fixture.client("a", binding: a)
        let second = try fixture.client("b", binding: b)
        let bytes = Data("library a attachment".utf8)
        let blob = try first.blobs.put(bytes)
        let capture = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        let operation = try first.enqueue(captureID: capture.id, mutation: .create(capture))
        #expect(throws: SyncBindingError.mismatch) {
            try fixture.client("a", binding: a, blobDirectory: second.blobs.directory)
        }
        #expect(throws: SyncBindingError.mismatch) {
            try fixture.client("b", binding: b, blobDirectory: first.blobs.directory)
        }
        let reopened = try fixture.client("a", binding: a)
        #expect(reopened.blobs.binding == a)
        #expect(try reopened.pendingOperations() == [operation])
        #expect(try reopened.blobs.read(blob) == bytes)
    }

    @Test(arguments: ["missing", "empty", "replacement", "unmarked"])
    func boundClientReopenRequiresExistingMatchingBlobOwner(state: String) throws {
        let fixture = BlobOwnershipFixture()
        defer { fixture.clean() }
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let client = try fixture.client("bound", binding: binding)
        let bytes = Data("pending offline image".utf8)
        let blob = try client.blobs.put(bytes)
        let capture = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        let operation = try client.enqueue(captureID: capture.id, mutation: .create(capture))
        let directory =
            state == "replacement"
            ? fixture.root.appendingPathComponent("replacement") : client.blobs.directory
        if state == "unmarked" {
            try FileManager.default.removeItem(
                at: directory.appendingPathComponent("library-owner"))
        } else if state != "replacement" {
            try FileManager.default.removeItem(at: directory)
        }
        if state == "empty" || state == "replacement" {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        let database = fixture.root.appendingPathComponent("bound.sqlite")
        let before = try Data(contentsOf: database)
        let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(throws: SyncBindingError.mismatch) {
            try fixture.client("bound", binding: binding, blobDirectory: directory)
        }
        #expect(try Data(contentsOf: database) == before)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) == files)
        #expect(try client.pendingOperations() == [operation])
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("library-owner").path))
        if state == "replacement" {
            let reopened = try fixture.client("bound", binding: binding)
            #expect(reopened.deviceID == client.deviceID)
            #expect(try reopened.pendingOperations() == [operation])
            #expect(try reopened.blobs.read(blob) == bytes)
        }
    }

    @Test func emptyDirectoryCannotEnrollTwoLibraries() throws {
        let fixture = BlobOwnershipFixture()
        defer { fixture.clean() }
        let a = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let b = SyncLibraryBinding(libraryID: UUID(), serviceID: a.serviceID)
        let first = try fixture.client("a", binding: a)
        #expect(try first.pendingOperations().isEmpty)
        #expect(throws: SyncBindingError.mismatch) {
            try fixture.client("b", binding: b, blobDirectory: first.blobs.directory)
        }
        #expect(try fixture.client("a", binding: a).deviceID == first.deviceID)
    }

    @Test(arguments: [true, false])
    func designatedInitializerRejectsMismatchedStore(_ boundStore: Bool) throws {
        let fixture = BlobOwnershipFixture()
        defer { fixture.clean() }
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let other = SyncLibraryBinding(libraryID: binding.libraryID, serviceID: UUID())
        let writer = try SyncDatabase.open(at: fixture.root.appendingPathComponent("client.sqlite"))
        let blobs = try BlobStore(
            directory: fixture.root.appendingPathComponent("blobs"),
            binding: boundStore ? other : nil)
        #expect(throws: SyncBindingError.mismatch) {
            try SyncClient(writer: writer, blobs: blobs, binding: binding)
        }
        #expect(try writer.read { try !$0.tableExists("sync_binding") })
        #expect(try writer.read { try !$0.tableExists("sync_meta") })
    }

    @Test func failedEnrollmentDoesNotClaimLegacyBlobDirectory() throws {
        let fixture = BlobOwnershipFixture()
        defer { fixture.clean() }
        let original = try fixture.client("legacy", binding: nil)
        let capture = SharedCapture(
            source: CaptureSource(kind: .text, selection: "keep queued text"))
        let operation = try original.enqueue(captureID: capture.id, mutation: .create(capture))
        #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
            try fixture.client(
                "legacy", binding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()))
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: original.blobs.directory.appendingPathComponent("library-owner").path))
        #expect(try fixture.client("legacy", binding: nil).pendingOperations() == [operation])
    }

    @Test func bindingMismatchDoesNotClaimAnotherEmptyDirectory() throws {
        let fixture = BlobOwnershipFixture()
        defer { fixture.clean() }
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        _ = try fixture.client("bound", binding: binding)
        let other = SyncLibraryBinding(libraryID: UUID(), serviceID: binding.serviceID)
        let directory = fixture.root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: SyncBindingError.mismatch) {
            try fixture.client("bound", binding: other, blobDirectory: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

private struct BlobOwnershipFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("capd-owner-\(UUID())")

    func client(
        _ name: String, binding: SyncLibraryBinding?, blobDirectory: URL? = nil
    ) throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("\(name).sqlite"),
            blobDirectory: blobDirectory ?? root.appendingPathComponent("\(name)-blobs"),
            binding: binding)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
