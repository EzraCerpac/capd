import Foundation
import Testing

@testable import CapdSync

@Suite("Cache eviction and authority ownership")
struct CacheAndAuthorityRegressionTests {
    @Test(arguments: [false, true])
    func unrelatedEnqueuesPreserveImagesWithUnavailableCache(corrupt: Bool) throws {
        let fixture = try CacheAuthorityFixture()
        defer { fixture.clean() }
        let client = try fixture.client()
        let bytes = Data("accepted image".utf8)
        let blob = try client.blobs.put(bytes)
        let image = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        try client.enqueue(captureID: image.id, mutation: .create(image))
        try client.push(to: fixture.server)
        try client.pull(from: fixture.server)
        let accepted = try #require(client.captures().first)
        try fixture.invalidate(blob, in: client.blobs, corrupt: corrupt)

        let text = SharedCapture(source: CaptureSource(kind: .text, selection: "offline text"))
        let create = try client.enqueue(captureID: text.id, mutation: .create(text))
        let edit = try client.enqueue(
            captureID: text.id, mutation: .edit(CaptureEdit(note: NoteEdit("offline note"))))
        #expect(try client.pendingOperations() == [create, edit])
        #expect(try client.captures().first { $0.id == image.id } == accepted)
        #expect(try client.captures().first { $0.id == text.id }?.note == "offline note")
        try client.push(to: fixture.server)
        #expect(try client.pendingOperations().isEmpty)

        _ = try fixture.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: image.id,
                baseRevision: accepted.revision, mutation: .recapture))
        try client.pull(from: fixture.server)
        #expect(try client.blobs.read(blob) == bytes)
        #expect(try client.captures().first { $0.id == image.id }?.seenCount == 2)
    }

    @Test(arguments: [false, true])
    func unavailableAssetsRejectNewImagesAndRestores(corrupt: Bool) throws {
        let fixture = try CacheAuthorityFixture()
        defer { fixture.clean() }
        let client = try fixture.client()
        let bytes = Data("restorable image".utf8)
        let blob = try client.blobs.put(bytes)
        let image = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        try client.enqueue(captureID: image.id, mutation: .create(image))
        try client.push(to: fixture.server)
        try client.enqueue(captureID: image.id, mutation: .delete)
        try client.push(to: fixture.server)
        let before = try client.captures(includeDeleted: true)
        try fixture.invalidate(blob, in: client.blobs, corrupt: corrupt)
        let incoming = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        let error: SyncError = corrupt ? .invalidBlob : .blobMissing
        #expect(throws: error) {
            try client.enqueue(captureID: incoming.id, mutation: .create(incoming))
        }
        #expect(throws: error) {
            try client.enqueue(captureID: image.id, mutation: .restore)
        }
        #expect(try client.pendingOperations().isEmpty)
        #expect(try client.captures(includeDeleted: true) == before)
        _ = try client.blobs.put(bytes)
        #expect(try client.enqueue(captureID: image.id, mutation: .restore).sequence == 3)
        #expect(try client.captures().first?.id == image.id)
    }

    @Test(arguments: ["missing", "empty", "unmarked"])
    func boundReopenRequiresMatchingOwnerWithoutClaimingDirectory(state: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("authority.sqlite")
        let directory = root.appendingPathComponent("assets")
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        do {
            let server = try SyncServer(
                databaseURL: database, blobDirectory: directory,
                libraryID: binding.libraryID, serviceID: binding.serviceID)
            _ = try server.blobs.put(Data("authority asset".utf8))
        }
        if state == "unmarked" {
            try FileManager.default.removeItem(
                at: directory.appendingPathComponent("library-owner"))
        } else {
            try FileManager.default.removeItem(at: directory)
            if state == "empty" {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            }
        }
        let before = try Data(contentsOf: database)
        let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(throws: SyncBindingError.mismatch) {
            try SyncServer(
                databaseURL: database, blobDirectory: directory,
                libraryID: binding.libraryID, serviceID: binding.serviceID)
        }
        #expect(try Data(contentsOf: database) == before)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) == files)
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("library-owner").path))
    }

    @Test func freshAuthorityClaimsDirectoryAndReopens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("authority.sqlite")
        let directory = root.appendingPathComponent("assets")
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let first = try SyncServer(
            databaseURL: database, blobDirectory: directory,
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        let bytes = Data("new authority image".utf8)
        let blob = try first.blobs.put(bytes)
        let reopened = try SyncServer(
            databaseURL: database, blobDirectory: directory,
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        #expect(try reopened.download(blob) == bytes)
        #expect(try reopened.baseline().captures.isEmpty)
    }
}

private struct CacheAuthorityFixture {
    let root: URL
    let server: SyncServer

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-assets"))
    }

    func client() throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("client.sqlite"),
            blobDirectory: root.appendingPathComponent("client-assets"))
    }

    func invalidate(_ blob: BlobReference, in store: BlobStore, corrupt: Bool) throws {
        let path = store.directory.appendingPathComponent(blob.digest)
        if corrupt {
            try Data("corrupt".utf8).write(to: path, options: .atomic)
        } else {
            try FileManager.default.removeItem(at: path)
        }
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
