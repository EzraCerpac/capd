import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdSyncAdministration

@Suite("Offline reviewed snapshot administration")
struct AdministrationTests {
    @Test func incompleteOrForeignDatabaseIsNotRepairedOrRebound() throws {
        for fault in ["incomplete", "role", "binding"] {
            let f = try Fixture()
            defer { f.clean() }
            let db = try DatabaseQueue(path: f.database.path)
            try db.write {
                switch fault {
                case "incomplete": try $0.execute(sql: "DROP TABLE sync_records")
                case "role": try $0.execute(sql: "UPDATE sync_meta SET role = 'client'")
                default:
                    let other = SyncLibraryBinding(
                        libraryID: UUID(), serviceID: f.binding.serviceID)
                    try $0.execute(
                        sql: "UPDATE sync_binding SET payload = ?",
                        arguments: [try Fixture.encode(other)])
                }
            }
            let before = try Data(contentsOf: f.database)
            #expect(throws: AdministrationError.invalidAuthority) { try f.admin() }
            #expect(try Data(contentsOf: f.database) == before)
            if fault == "incomplete" {
                #expect(try db.read { try $0.tableExists("sync_records") } == false)
            }
        }
    }

    @Test func legacyBoundAuthorityIsRejectedWithoutMigratingIt() throws {
        let f = try Fixture()
        defer { f.clean() }
        let record = SharedCapture(source: CaptureSource(kind: .text, selection: "legacy"))
        _ = try f.server().apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: record.id,
                baseRevision: 0, mutation: .create(record)))
        let db = try DatabaseQueue(path: f.database.path)
        try db.write {
            try $0.execute(
                sql: """
                    DROP INDEX sync_records_identity;
                    ALTER TABLE sync_records RENAME TO sync_records_current;
                    CREATE TABLE sync_records (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                    INSERT INTO sync_records (id, payload)
                    SELECT id, payload FROM sync_records_current;
                    DROP TABLE sync_records_current;
                    """)
        }
        let legacyColumns = try db.read { try $0.columns(in: "sync_records").map(\.name) }
        let legacyIDs = try db.read {
            try String.fetchAll($0, sql: "SELECT id FROM sync_records ORDER BY id")
        }
        let legacyPayloads = try db.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_records ORDER BY id")
        }

        #expect(throws: AdministrationError.invalidAuthority) { try f.admin() }
        #expect(try db.read { try $0.columns(in: "sync_records").map(\.name) } == legacyColumns)
        #expect(
            try db.read {
                try String.fetchAll($0, sql: "SELECT id FROM sync_records ORDER BY id")
            } == legacyIDs)
        #expect(
            try db.read {
                try Data.fetchAll($0, sql: "SELECT payload FROM sync_records ORDER BY id")
            } == legacyPayloads)
        #expect(
            try db.read {
                try String.fetchOne(
                    $0,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
                    arguments: ["sync_records_identity"])
            } == nil)
    }

    @Test func resourceBoundsAndUnsafeBlobIdentifiersRefuseBeforeAssetReads() throws {
        for fault in ["count", "total", "path", "size"] {
            let f = try Fixture(image: true)
            defer { f.clean() }
            let count =
                fault == "count"
                ? SnapshotAdministration.maximumAssetCount + 1 : (fault == "total" ? 129 : 1)
            let captures = (0..<count).map { index in
                SharedCapture(
                    source: CaptureSource(
                        kind: .image,
                        blob: BlobReference(
                            digest: fault == "path" ? "../outside" : String(format: "%064x", index),
                            byteCount: 8_388_608)))
            }
            if fault == "size" {
                let blob = try #require(f.manifest.captures.first?.source.blob)
                let file = try FileHandle(
                    forWritingTo: f.assets.appendingPathComponent(blob.digest))
                try file.truncate(atOffset: 8_388_609)
                try file.close()
            } else {
                let oversized = ContentSnapshotImport(
                    snapshotID: UUID(), targetBinding: f.binding,
                    sourceDeviceID: UUID(), captures: captures)
                try Fixture.encode(oversized).write(to: f.snapshot)
            }
            #expect(throws: (any Error).self) {
                try f.admin().preview(snapshotURL: f.snapshot, assetDirectory: f.assets)
            }
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: f.blobs.path) == [
                    "library-owner"
                ])
            #expect(try f.server().baseline().captures.isEmpty)
        }
    }

    @Test func previewAndImportPreservePhoneHistoryAndUseSeparateReceipts() throws {
        let f = try Fixture()
        defer { f.clean() }
        let seed = SharedCapture(
            source: CaptureSource(kind: .text, contentHash: "same", selection: "same"))
        let accepted = SyncOperation(
            deviceID: UUID(), sequence: 1, captureID: seed.id,
            baseRevision: 0, mutation: .create(seed))
        let originalReceipt = try f.server().apply(accepted)
        let history = try f.history()
        let phoneRoot = f.root.appendingPathComponent("old-phone")
        let phoneDB = phoneRoot.appendingPathComponent("library.sqlite")
        let phone = try SyncClient(
            databaseURL: phoneDB,
            blobDirectory: phoneRoot.appendingPathComponent("blobs"), deviceID: UUID())
        let oldAuthority = try SyncServer(
            databaseURL: phoneRoot.appendingPathComponent("old-authority.sqlite"),
            blobDirectory: phoneRoot.appendingPathComponent("old-authority-blobs"))
        let priorCapture = SharedCapture(
            source: CaptureSource(kind: .text, selection: "old accepted"))
        let prior = try phone.enqueue(captureID: priorCapture.id, mutation: .create(priorCapture))
        _ = try phone.push(to: oldAuthority)
        var duplicate = SharedCapture(source: seed.source)
        duplicate.note = "old phone note"
        let queued = try phone.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        let next = try phone.enqueue(captureID: duplicate.id, mutation: .recapture)
        #expect(prior.sequence == 1 && queued.sequence == 2 && next.sequence == 3)
        let snapshot = try phone.contentSnapshotImport(snapshotID: UUID(), targetBinding: f.binding)
        try Fixture.encode(snapshot).write(to: f.snapshot)
        let phoneBytes = try f.phoneBytes(phoneDB)
        let admin = try f.admin()
        let review = try admin.preview(snapshotURL: f.snapshot, assetDirectory: f.assets)
        #expect(
            review.preview.items.first { $0.source.id == duplicate.id }?.canonicalCaptureID
                == seed.id)
        #expect(review.preview.items.allSatisfy { !$0.countIsExact })
        #expect(review.preview.countPolicy == .maximumKnownLowerBound)
        #expect(try f.history() == history)
        let hash = try SnapshotAdministration.writeReview(review, to: f.review)
        #expect(try Data(contentsOf: f.review).count > 0)
        let receipt = try admin.importSnapshot(
            snapshotURL: f.snapshot, assetDirectory: f.assets,
            reviewURL: f.review, reviewedSHA256: hash)
        #expect(receipt.items.allSatisfy { ![prior.id, queued.id, next.id].contains($0.id) })
        #expect(try f.history() == history)
        #expect(try phone.pendingOperations() == [queued, next])
        #expect(try f.phoneBytes(phoneDB) == phoneBytes)
        #expect(try f.server().apply(accepted) == originalReceipt)
        #expect(try f.server().baseline().deviceSequences[snapshot.sourceDeviceID] == nil)
        #expect(try f.server().expiredContentSnapshotFeed(snapshot.snapshotID).count == 1)
        #expect(
            try admin.importSnapshot(
                snapshotURL: f.snapshot, assetDirectory: f.assets,
                reviewURL: f.review, reviewedSHA256: hash) == receipt)
        let final = try #require(try f.server().baseline().captures.first { $0.id == seed.id })
        #expect(final.noteConflicts.contains { $0.value == duplicate.note })
        #expect(final.seenCount == 2)
    }

    @Test func existingAuthorityScopeAndExclusiveLockAreMandatory() throws {
        let f = try Fixture()
        defer { f.clean() }
        let db = try Data(contentsOf: f.database)
        let owner = try Data(contentsOf: f.blobs.appendingPathComponent("library-owner"))
        #expect(throws: AdministrationError.invalidAuthority) {
            try SnapshotAdministration(
                dataDirectory: f.data,
                binding: SyncLibraryBinding(libraryID: f.binding.libraryID, serviceID: UUID()))
        }
        do {
            let locked = try f.admin()
            #expect(throws: AdministrationError.authorityBusy) { try f.admin() }
            _ = locked
        }
        let marker = f.blobs.appendingPathComponent("library-owner")
        try FileManager.default.removeItem(at: marker)
        #expect(throws: (any Error).self) { try f.admin() }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try owner.write(to: marker)
        #expect(try Data(contentsOf: f.database) == db)
        let unowned = f.root.appendingPathComponent("unowned")
        try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try SnapshotAdministration(dataDirectory: unowned, binding: f.binding)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: unowned.path).isEmpty)
    }

    @Test func reviewedHashSnapshotBytesAndAuthorityStateMustStillMatch() throws {
        let f = try Fixture()
        defer { f.clean() }
        let (_, hash) = try f.prepare()
        do {
            let admin = try f.admin()
            #expect(throws: AdministrationError.invalidReview) {
                try admin.importSnapshot(
                    snapshotURL: f.snapshot, assetDirectory: f.assets,
                    reviewURL: f.review, reviewedSHA256: String(repeating: "0", count: 64))
            }
            let original = try Data(contentsOf: f.snapshot)
            try (original + Data("\n".utf8)).write(to: f.snapshot)
            #expect(throws: AdministrationError.changedInputs) {
                try admin.importSnapshot(
                    snapshotURL: f.snapshot, assetDirectory: f.assets,
                    reviewURL: f.review, reviewedSHA256: hash)
            }
            try original.write(to: f.snapshot)
        }
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "intervening"))
        _ = try f.server().apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: capture.id,
                baseRevision: 0, mutation: .create(capture)))
        let admin = try f.admin()
        #expect(throws: AdministrationError.staleReview) {
            try admin.importSnapshot(
                snapshotURL: f.snapshot, assetDirectory: f.assets,
                reviewURL: f.review, reviewedSHA256: hash)
        }
        #expect(try f.server().baseline().captures.count == 1)
        #expect(try f.server().baseline().captures.first?.id == capture.id)
        #expect(try f.server().retainedContentSnapshotImport(f.manifest.snapshotID) == nil)
    }

    @Test func verifiedAssetsArePublishedOnlyAfterReviewAndExactRetrySurvivesReopen() throws {
        let f = try Fixture(image: true)
        defer { f.clean() }
        let blob = try #require(f.manifest.captures.first?.source.blob)
        let (review, hash) = try f.prepare()
        #expect(review.assets == [blob])
        let destination = f.blobs.appendingPathComponent(blob.digest)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let receipt: ContentSnapshotImportReceipt
        do {
            let admin = try f.admin()
            receipt = try admin.importSnapshot(
                snapshotURL: f.snapshot, assetDirectory: f.assets,
                reviewURL: f.review, reviewedSHA256: hash)
        }
        #expect(try Data(contentsOf: destination) == f.image)
        #expect(
            try f.admin().importSnapshot(
                snapshotURL: f.snapshot, assetDirectory: f.assets,
                reviewURL: f.review, reviewedSHA256: hash) == receipt)
        #expect(
            (try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize == blob.byteCount)
    }

    @Test func changedMissingAndSymlinkAssetsRefuseWithoutMutation() throws {
        for fault in ["changed", "missing", "symlink", "authoritySymlink", "authorityCorrupt"] {
            let f = try Fixture(image: true)
            defer { f.clean() }
            let (_, hash) = try f.prepare()
            let blob = try #require(f.manifest.captures.first?.source.blob)
            let source = f.assets.appendingPathComponent(blob.digest)
            let destination = f.blobs.appendingPathComponent(blob.digest)
            switch fault {
            case "changed": try Data("invalid".utf8).write(to: source)
            case "missing": try FileManager.default.removeItem(at: source)
            case "symlink":
                try FileManager.default.removeItem(at: source)
                try FileManager.default.createSymbolicLink(
                    at: source, withDestinationURL: f.snapshot)
            case "authoritySymlink":
                try FileManager.default.createSymbolicLink(
                    at: destination, withDestinationURL: source)
            default: try Data("invalid".utf8).write(to: destination)
            }
            let admin = try f.admin()
            #expect(throws: (any Error).self) {
                try admin.importSnapshot(
                    snapshotURL: f.snapshot, assetDirectory: f.assets,
                    reviewURL: f.review, reviewedSHA256: hash)
            }
            #expect(try f.server().baseline().captures.isEmpty)
            #expect(try f.server().retainedContentSnapshotImport(f.manifest.snapshotID) == nil)
            if fault == "authorityCorrupt" {
                #expect(try Data(contentsOf: destination) == Data("invalid".utf8))
            }
            if fault != "authorityCorrupt" && fault != "authoritySymlink" {
                #expect(!FileManager.default.fileExists(atPath: destination.path))
            }
        }
    }

    @Test func failedDatabaseTransactionRollsBackNewAssetsAndOriginalHistory() throws {
        let f = try Fixture(image: true)
        defer { f.clean() }
        let (_, hash) = try f.prepare()
        let db = try DatabaseQueue(path: f.database.path)
        try db.write {
            try $0.execute(
                sql:
                    "CREATE TRIGGER reject_import BEFORE INSERT ON sync_records BEGIN SELECT RAISE(ABORT, 'synthetic'); END;"
            )
        }
        let before = try f.history()
        let admin = try f.admin()
        #expect(throws: (any Error).self) {
            try admin.importSnapshot(
                snapshotURL: f.snapshot, assetDirectory: f.assets,
                reviewURL: f.review, reviewedSHA256: hash)
        }
        #expect(try f.server().baseline().captures.isEmpty)
        #expect(try f.history() == before)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: f.blobs.path) == ["library-owner"])
        #expect(try f.server().retainedContentSnapshotImport(f.manifest.snapshotID) == nil)
    }

    @Test func reviewPublicationIsPrivateAndRefusesOverwriteOrSymlink() throws {
        let f = try Fixture()
        defer { f.clean() }
        let (review, hash) = try f.prepare()
        #expect(hash == BlobReference(data: try Data(contentsOf: f.review)).digest)
        let permissions =
            try FileManager.default.attributesOfItem(atPath: f.review.path)[.posixPermissions]
            as? Int
        #expect(permissions == 0o600)
        let original = try Data(contentsOf: f.review)
        #expect(throws: AdministrationError.unsafePath) {
            try SnapshotAdministration.writeReview(review, to: f.review)
        }
        #expect(try Data(contentsOf: f.review) == original)
        let link = f.root.appendingPathComponent("review-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.review)
        #expect(throws: AdministrationError.unsafePath) {
            try SnapshotAdministration.writeReview(review, to: link)
        }
        #expect(try Data(contentsOf: f.review) == original)
    }

    @Test func commandLinePreviewAndImportUseExplicitReviewedArtifact() throws {
        let f = try Fixture(image: true)
        defer { f.clean() }
        let binary = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("capd-sync-admin")
        let common = [
            "--data-dir", f.data.path, "--service-id", f.binding.serviceID.uuidString,
            "--library-id", f.binding.libraryID.uuidString, "--snapshot", f.snapshot.path,
            "--assets", f.assets.path, "--review", f.review.path,
        ]
        let preview = try run(binary, ["preview"] + common)
        #expect(preview.status == 0)
        #expect(preview.output.contains("counts are lower bounds"))
        let hash = BlobReference(data: try Data(contentsOf: f.review)).digest
        #expect(preview.output.contains(hash))
        #expect(try run(binary, ["import"] + common).status == 1)
        let imported = try run(binary, ["import"] + common + ["--reviewed-sha256", hash])
        #expect(imported.status == 0)
        let receipt = try JSONDecoder().decode(
            ContentSnapshotImportReceipt.self, from: Data(imported.output.utf8))
        #expect(receipt.snapshotID == f.manifest.snapshotID)
        #expect(receipt.countPolicy == .maximumKnownLowerBound)
        let repeated = try run(binary, ["import"] + common + ["--reviewed-sha256", hash])
        #expect(repeated.status == 0)
        #expect(repeated.output == imported.output)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws -> (
        status: Int32, output: String
    ) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }
}

private final class TestBundleMarker: NSObject {}

private struct Fixture {
    let root: URL
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let image = Data("synthetic image bytes".utf8)
    let manifest: ContentSnapshotImport
    var data: URL { root.appendingPathComponent("authority") }
    var library: URL { data.appendingPathComponent(binding.libraryID.uuidString.lowercased()) }
    var database: URL { library.appendingPathComponent("authority.sqlite") }
    var blobs: URL { library.appendingPathComponent("blobs") }
    var snapshot: URL { root.appendingPathComponent("snapshot.json") }
    var assets: URL { root.appendingPathComponent("assets") }
    var review: URL { root.appendingPathComponent("review.json") }

    init(image hasImage: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capd-admin-\(UUID())")
        let source =
            hasImage
            ? CaptureSource(kind: .image, contentHash: "image", blob: BlobReference(data: image))
            : CaptureSource(kind: .text, contentHash: "phone", selection: "phone")
        var capture = SharedCapture(source: source)
        capture.seenCount = 7
        manifest = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: binding,
            sourceDeviceID: UUID(), captures: [capture])
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Self.encode(binding.serviceID).write(to: data.appendingPathComponent("service.json"))
        try Data().write(to: data.appendingPathComponent(".server.lock"))
        _ = try server()
        try Self.encode(manifest).write(to: snapshot)
        if hasImage {
            try image.write(to: assets.appendingPathComponent(BlobReference(data: image).digest))
        }
    }

    func server() throws -> SyncServer {
        try SyncServer(
            databaseURL: database, blobDirectory: blobs,
            libraryID: binding.libraryID, serviceID: binding.serviceID)
    }
    func admin() throws -> SnapshotAdministration {
        try SnapshotAdministration(dataDirectory: data, binding: binding)
    }
    func prepare() throws -> (SnapshotReview, String) {
        let admin = try admin()
        let review = try admin.preview(snapshotURL: snapshot, assetDirectory: assets)
        return (review, try SnapshotAdministration.writeReview(review, to: self.review))
    }
    func history() throws -> [Data] {
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: database.path, configuration: config).read {
            try Data.fetchAll($0, sql: "SELECT operation FROM sync_receipts ORDER BY id")
                + Data.fetchAll($0, sql: "SELECT receipt FROM sync_receipts ORDER BY id")
                + String.fetchAll(
                    $0, sql: "SELECT id || ':' || sequence FROM sync_devices ORDER BY id"
                ).map { Data($0.utf8) }
        }
    }
    func phoneBytes(_ url: URL) throws -> [Data] {
        try [url, URL(fileURLWithPath: url.path + "-wal")].map {
            FileManager.default.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : Data()
        }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
