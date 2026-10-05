import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdSyncAdministration

@Suite("Read-only snapshot preview")
struct ReadonlyPreviewTests {
    @Test func deleteJournalPreviewLeavesAuthorityAndFilesUnchanged() throws {
        let f = try Fixture()
        defer { f.clean() }
        let before = try f.fileBytes()
        let journalMode = try f.journalMode()
        #expect(journalMode == "delete")

        let admin = try f.admin()
        let review = try admin.preview(snapshotURL: f.snapshot, assetDirectory: f.assets)

        #expect(review.preview.items.count == f.manifest.captures.count)
        #expect(try f.fileBytes() == before)
        #expect(try f.journalMode() == journalMode)

        _ = try SnapshotAdministration.writeReview(review, to: f.review)
        var afterReview = before
        try afterReview[f.relativePath(f.review)] = try Data(contentsOf: f.review)
        #expect(try f.fileBytes() == afterReview)
        #expect(try f.journalMode() == journalMode)
    }

    @Test func previewRefusesUncheckpointedWALWithoutChangingAuthorityFiles() throws {
        let f = try Fixture()
        defer { f.clean() }
        let writer = try f.server()
        defer { withExtendedLifetime(writer) {} }
        let source = try #require(f.manifest.captures.first?.source)
        let seed = SharedCapture(source: source)
        _ = try writer.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: seed.id,
                baseRevision: 0, mutation: .create(seed)
            )
        )

        let before = try f.fileBytes()
        #expect(try f.journalMode() == "wal")
        #expect(try Data(contentsOf: f.sidecar("-wal")).count > 0)
        #expect(try Data(contentsOf: f.sidecar("-shm")).count > 0)

        #expect(throws: AdministrationError.authorityNeedsRecovery) { try f.admin() }
        #expect(throws: SyncServer.SnapshotPreviewError.authorityNeedsRecovery) {
            try SyncServer.previewContentSnapshotImport(
                f.manifest, databaseURL: f.database, binding: f.binding)
        }
        #expect(try f.fileBytes() == before)
        #expect(try f.journalMode() == "wal")
    }

    @Test func previewRefusesNonemptyRollbackJournalWithoutChangingFiles() throws {
        let f = try Fixture()
        defer { f.clean() }
        try Data("pending synthetic recovery".utf8).write(to: f.sidecar("-journal"))
        let before = try f.fileBytes()
        #expect(throws: AdministrationError.authorityNeedsRecovery) { try f.admin() }
        #expect(throws: SyncServer.SnapshotPreviewError.authorityNeedsRecovery) {
            try SyncServer.previewContentSnapshotImport(
                f.manifest, databaseURL: f.database, binding: f.binding)
        }
        #expect(try f.fileBytes() == before)
    }

    @Test func checkpointedWALPreviewCreatesNoSidecarsOrChangesAuthorityFiles() throws {
        let f = try Fixture()
        defer { f.clean() }
        #expect(try f.enableWAL(checkpoint: true) == "wal")
        #expect(!FileManager.default.fileExists(atPath: f.sidecar("-wal").path))
        #expect(!FileManager.default.fileExists(atPath: f.sidecar("-shm").path))
        let before = try f.fileBytes()

        let admin = try f.admin()
        let review = try admin.preview(snapshotURL: f.snapshot, assetDirectory: f.assets)

        #expect(review.preview.items.count == f.manifest.captures.count)
        #expect(try f.fileBytes() == before)
        #expect(try f.journalMode() == "wal")
        let hash = try SnapshotAdministration.writeReview(review, to: f.review)
        let receipt = try admin.importSnapshot(
            snapshotURL: f.snapshot, assetDirectory: f.assets,
            reviewURL: f.review, reviewedSHA256: hash)
        #expect(receipt.snapshotID == f.manifest.snapshotID)
    }

    @Test func invalidReviewedHashDoesNotChangeAuthorityFiles() throws {
        let f = try Fixture()
        defer { f.clean() }
        let admin = try f.admin()
        let review = try admin.preview(snapshotURL: f.snapshot, assetDirectory: f.assets)
        _ = try SnapshotAdministration.writeReview(review, to: f.review)
        let before = try f.fileBytes()

        #expect(throws: AdministrationError.invalidReview) {
            try admin.importSnapshot(
                snapshotURL: f.snapshot, assetDirectory: f.assets,
                reviewURL: f.review, reviewedSHA256: String(repeating: "0", count: 64)
            )
        }

        #expect(try f.fileBytes() == before)
    }
}

private struct Fixture {
    let root: URL
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let manifest: ContentSnapshotImport
    var data: URL {
        root.appendingPathComponent("authority")
    }

    var library: URL {
        data.appendingPathComponent(binding.libraryID.uuidString.lowercased())
    }

    var database: URL {
        library.appendingPathComponent("authority.sqlite")
    }

    var blobs: URL {
        library.appendingPathComponent("blobs")
    }

    var snapshot: URL {
        root.appendingPathComponent("snapshot.json")
    }

    var assets: URL {
        root.appendingPathComponent("assets")
    }

    var review: URL {
        root.appendingPathComponent("review.json")
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capd-admin-readonly-\(UUID())")
        let capture = SharedCapture(
            source: CaptureSource(kind: .text, contentHash: "preview", selection: "preview")
        )
        manifest = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: binding,
            sourceDeviceID: UUID(), captures: [capture]
        )
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Self.encode(binding.serviceID).write(to: data.appendingPathComponent("service.json"))
        try Data().write(to: data.appendingPathComponent(".server.lock"))
        _ = try server()
        let queue = try DatabaseQueue(path: database.path)
        try queue.writeWithoutTransaction { db in
            let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE")
            #expect(mode == "delete")
        }
        try queue.close()
        try Self.encode(manifest).write(to: snapshot)
    }

    func server() throws -> SyncServer {
        try SyncServer(
            databaseURL: database, blobDirectory: blobs,
            libraryID: binding.libraryID, serviceID: binding.serviceID
        )
    }

    func admin() throws -> SnapshotAdministration {
        try SnapshotAdministration(dataDirectory: data, binding: binding)
    }

    func enableWAL(checkpoint: Bool = false) throws -> String {
        var queue: DatabaseQueue? = try DatabaseQueue(path: database.path)
        let mode = try queue!.writeWithoutTransaction { db in
            let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
            if checkpoint {
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            return try #require(mode)
        }
        try queue!.close()
        queue = nil
        if checkpoint {
            for suffix in ["-wal", "-shm"] {
                let file = sidecar(suffix)
                if FileManager.default.fileExists(atPath: file.path) {
                    if suffix == "-wal" { #expect(try Data(contentsOf: file).isEmpty) }
                    try FileManager.default.removeItem(at: file)
                }
            }
        }
        return mode
    }

    func journalMode() throws -> String {
        let header = try Data(contentsOf: database)
        try #require(header.count >= 20)
        return header[18] == 2 && header[19] == 2 ? "wal" : "delete"
    }

    func fileBytes() throws -> [String: Data] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        var files: [String: Data] = [:]
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            try files[relativePath(url)] = try Data(contentsOf: url)
        }
        return files
    }

    func relativePath(_ url: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { throw CocoaError(.fileReadInvalidFileName) }
        return String(path.dropFirst(rootPath.count))
    }

    func sidecar(_ suffix: String) -> URL {
        URL(fileURLWithPath: database.path + suffix)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }
}
