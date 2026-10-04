import Foundation
import GRDB
import Testing

@testable import CapdSync

@Suite("Snapshot import regressions")
struct SnapshotImportRegressionTests {
    @Test func legacyDuplicateRowsUseFirstCanonicalTombstone() throws {
        let fixture = try SnapshotRegressionFixture()
        defer { fixture.clean() }
        var first = fixture.capture(id: fixture.authorityID)
        first.deleted = true
        let second = fixture.capture(id: fixture.sourceID)
        let writer = try SyncDatabase.open(
            at: fixture.root.appendingPathComponent("authority.sqlite"))
        try writer.write { db in
            try db.execute(
                sql: """
                    DROP TABLE sync_records;
                    CREATE TABLE sync_records (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                    """)
            for capture in [first, second] {
                try db.execute(
                    sql: "INSERT INTO sync_records (id, payload) VALUES (?, ?)",
                    arguments: [capture.id.uuidString, try SyncDatabase.encode(capture)])
            }
        }
        let migrated = try fixture.openServer()
        #expect(try migrated.baseline().captures == [first, second])
        let incoming = fixture.capture(id: fixture.laterID)
        let snapshot = fixture.snapshot([incoming])
        let preview = try migrated.previewContentSnapshotImport(snapshot)
        #expect(preview.items.first?.canonicalCaptureID == first.id)
        #expect(preview.items.first?.disposition == .preserveTombstone)
        #expect(preview.items.first?.authority == first)
        let receipt = try migrated.importContentSnapshot(snapshot, preview: preview)
        #expect(receipt.items.first?.canonicalCaptureID == first.id)
        #expect(try migrated.baseline().captures == [first, second])
        #expect(try fixture.openServer().baseline().captures == [first, second])
    }

    @Test(arguments: [false, true])
    func incomingTombstoneDeletesLiveAuthorityAndLaterSnapshotAliases(matchID: Bool) throws {
        let fixture = try SnapshotRegressionFixture()
        defer { fixture.clean() }
        let original = fixture.capture(id: fixture.authorityID)
        try fixture.server.apply(fixture.operation(original, sequence: 1))
        var deleted = fixture.capture(
            id: matchID ? original.id : fixture.sourceID)
        deleted.deleted = true
        deleted.seenCount = 20
        let laterLive = fixture.capture(id: fixture.laterID)
        let snapshot = fixture.snapshot([deleted, laterLive])
        let preview = try fixture.server.previewContentSnapshotImport(snapshot)
        #expect(preview.items.map(\.disposition) == [.preserveTombstone, .preserveTombstone])
        #expect(preview.items.map(\.canonicalCaptureID) == [original.id, original.id])
        #expect(preview.items[1].authority?.deleted == true)
        #expect(preview.items[1].authority?.revision == preview.authorityCursor + 1)
        #expect(preview.items.map(\.proposedSeenCount) == [1, 1])
        let receipt = try fixture.server.importContentSnapshot(snapshot, preview: preview)
        let result = try #require(try fixture.server.baseline().captures.first)
        #expect(result.deleted)
        #expect(result.revision == receipt.authorityCursor)
        #expect(result.seenCount == original.seenCount)
        #expect(result.note == original.note)
        #expect(try fixture.server.importContentSnapshot(snapshot, preview: preview) == receipt)
        let reopened = try fixture.openServer()
        #expect(try reopened.baseline().captures.first == result)
    }

    @Test(arguments: [Int.max - 1, Int.max])
    func importedCountsSaturateAcrossRecapturesAndDeduplicatedCreates(count: Int) throws {
        let fixture = try SnapshotRegressionFixture()
        defer { fixture.clean() }
        var incoming = fixture.capture(id: fixture.authorityID)
        incoming.seenCount = count
        let snapshot = fixture.snapshot([incoming])
        try fixture.server.importContentSnapshot(
            snapshot, preview: fixture.server.previewContentSnapshotImport(snapshot))
        for sequence in 1...2 {
            let revision = try #require(try fixture.server.baseline().captures.first?.revision)
            try fixture.server.apply(
                SyncOperation(
                    deviceID: fixture.deviceID, sequence: Int64(sequence), captureID: incoming.id,
                    baseRevision: revision, mutation: .recapture))
            #expect(try fixture.server.baseline().captures.first?.seenCount == Int.max)
        }
        let duplicate = fixture.capture(id: fixture.sourceID)
        try fixture.server.apply(fixture.operation(duplicate, sequence: 3))
        let captures = try fixture.server.baseline().captures
        #expect(captures.count == 1)
        #expect(captures.first?.id == incoming.id)
        #expect(captures.first?.seenCount == Int.max)
        #expect(try fixture.openServer().baseline().captures == captures)
    }
}

private struct SnapshotRegressionFixture {
    let root: URL
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let deviceID = UUID()
    let authorityID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let laterID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    let server: SyncServer

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-snapshot-regression-\(UUID())")
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
    }

    func openServer() throws -> SyncServer {
        try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
    }

    func capture(id: UUID) -> SharedCapture {
        SharedCapture(
            id: id, source: CaptureSource(kind: .text, contentHash: "same", selection: "same"),
            createdAt: Date(timeIntervalSinceReferenceDate: 123), note: "Preserved note")
    }

    func operation(_ capture: SharedCapture, sequence: Int64) -> SyncOperation {
        SyncOperation(
            deviceID: deviceID, sequence: sequence, captureID: capture.id, baseRevision: 0,
            mutation: .create(capture))
    }

    func snapshot(_ captures: [SharedCapture]) -> ContentSnapshotImport {
        ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: binding, sourceDeviceID: UUID(), captures: captures)
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
