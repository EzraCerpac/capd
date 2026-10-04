import Foundation
import GRDB
import Testing

@testable import CapdSync

@Suite("Blob storage boundaries")
struct BlobBoundaryTests {
    @Test(arguments: [false, true])
    func symlinkedPublishedAndPartialLeavesAreNotRead(partial: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BlobStore(directory: root.appendingPathComponent("blobs"))
        let bytes = Data("synthetic external blob".utf8)
        let blob = BlobReference(data: bytes)
        let target = root.appendingPathComponent("outside")
        try bytes.write(to: target)
        let leaf = store.directory.appendingPathComponent(blob.digest + (partial ? ".partial" : ""))
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
        #expect(throws: SyncError.invalidBlob) {
            if partial {
                try store.receive(blob, offset: bytes.count, chunk: Data(), final: true)
            } else {
                _ = try store.read(blob)
            }
        }
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: leaf.path) == target.path)
        if partial {
            #expect(
                !FileManager.default.fileExists(
                    atPath: store.directory.appendingPathComponent(blob.digest).path))
        }
    }

    @Test(arguments: [false, true], [false, true])
    func invalidExistingOwnerCannotCreateOrBindDatabase(existingDatabase: Bool, malformed: Bool)
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = root.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let owner = blobs.appendingPathComponent("library-owner")
        let marker =
            malformed
            ? Data("invalid owner".utf8)
            : try JSONEncoder().encode(
                SyncLibraryBinding(libraryID: UUID(), serviceID: binding.serviceID))
        try marker.write(to: owner)
        let database = root.appendingPathComponent("authority.sqlite")
        var original: Data?
        if existingDatabase {
            let writer = try DatabaseQueue(path: database.path)
            try writer.write { db in
                try db.execute(
                    sql:
                        "CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES ('untouched')"
                )
            }
            try writer.close()
            original = try Data(contentsOf: database)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(throws: SyncBindingError.mismatch) {
            _ = try SyncServer(
                databaseURL: database, blobDirectory: blobs, libraryID: binding.libraryID,
                serviceID: binding.serviceID)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == entries)
        #expect(try Data(contentsOf: owner) == marker)
        if let original {
            #expect(try Data(contentsOf: database) == original)
        } else {
            #expect(!FileManager.default.fileExists(atPath: database.path))
        }
    }
}
