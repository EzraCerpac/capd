import Foundation
import GRDB
import Testing

@testable import CapdSync

struct LegacyServiceRetryTests {
    @Test func ownedLegacyCreateAndEditReplayWithoutChangingHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("authority.sqlite")
        let blobs = root.appendingPathComponent("blobs")
        let server = try SyncServer(databaseURL: database, blobDirectory: blobs)
        let device = UUID()
        let principal = "synthetic-service"
        try server.reserveServiceWriter(deviceID: device, principalID: principal)
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "synthetic text"))
        let create = SyncOperation(
            deviceID: device, sequence: 1, captureID: capture.id, baseRevision: 0,
            mutation: .create(capture))
        let created = try server.apply(create, servicePrincipalID: principal)
        let edit = SyncOperation(
            deviceID: device, sequence: 2, captureID: capture.id, baseRevision: 1,
            mutation: .edit(CaptureEdit(note: NoteEdit("synthetic edit"), rating: 4)))
        let edited = try server.apply(edit, servicePrincipalID: principal)
        let reader = try DatabaseQueue(path: database.path)
        func history() throws -> [Row] {
            try reader.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM sync_receipts ORDER BY id")
                    + Row.fetchAll(db, sql: "SELECT * FROM sync_feed ORDER BY cursor")
            }
        }
        let before = try history()
        let baseline = try server.baseline()
        let reopened = try SyncServer(databaseURL: database, blobDirectory: blobs)
        for (original, receipt) in [(create, created), (edit, edited)] {
            let retry = SyncOperation(
                id: original.id, deviceID: device, sequence: original.sequence,
                captureID: original.captureID, baseRevision: original.baseRevision,
                mutation: original.mutation, requestIdentity: .object(["sha256": .string("new")]))
            for _ in 0..<3 {
                #expect(try reopened.apply(retry, servicePrincipalID: principal) == receipt)
            }
        }
        #expect(try history() == before)
        #expect(try reopened.baseline().cursor == baseline.cursor)
        #expect(try reopened.baseline().captures == baseline.captures)
        #expect(try reopened.baseline().deviceSequences == baseline.deviceSequences)
    }

    @Test func legacyServiceRetryRejectsChangedFieldsAndOtherOwners() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("blobs"))
        let device = UUID()
        try server.reserveServiceWriter(deviceID: device, principalID: "service")
        let original = SyncOperation(
            deviceID: device, sequence: 1, captureID: UUID(), baseRevision: 0,
            mutation: .edit(CaptureEdit(note: NoteEdit("synthetic"))))
        let receipt = try server.apply(original, servicePrincipalID: "service")
        func retry(
            sequence: Int64 = 1, captureID: UUID? = nil, base: Int64 = 0,
            predecessor: UUID? = nil, mutation: CaptureMutation? = nil
        ) -> SyncOperation {
            SyncOperation(
                id: original.id, deviceID: device, sequence: sequence,
                captureID: captureID ?? original.captureID, baseRevision: base,
                predecessorID: predecessor, mutation: mutation ?? original.mutation,
                requestIdentity: .object(["sha256": .string("new")]))
        }
        let before = try server.baseline()
        for changed in [
            retry(sequence: 2), retry(captureID: UUID()), retry(base: 1),
            retry(predecessor: UUID()), retry(mutation: .delete),
            retry(mutation: .edit(CaptureEdit(note: NoteEdit("different")))),
        ] {
            #expect(throws: SyncError.operationIDReused) {
                try server.apply(changed, servicePrincipalID: "service")
            }
        }
        for principal in [nil, "other-service"] {
            #expect(throws: SyncError.wrongDevice) {
                try server.apply(retry(), servicePrincipalID: principal)
            }
        }
        let otherDevice = SyncOperation(
            id: original.id, deviceID: UUID(), sequence: 1, captureID: original.captureID,
            baseRevision: 0, mutation: original.mutation,
            requestIdentity: .object(["sha256": .string("new")]))
        #expect(throws: SyncError.wrongDevice) {
            try server.apply(otherDevice, servicePrincipalID: "service")
        }
        #expect(try server.apply(retry(), servicePrincipalID: "service") == receipt)
        #expect(try server.baseline().cursor == before.cursor)
        #expect(try server.baseline().deviceSequences == before.deviceSequences)
    }

    @Test func ordinaryLegacyAndModernServiceIdentitiesStayStrict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("blobs"))
        let ordinary = SyncOperation(
            deviceID: UUID(), sequence: 1, captureID: UUID(), baseRevision: 0,
            mutation: .recapture)
        _ = try server.apply(ordinary)
        let ordinaryRetry = SyncOperation(
            id: ordinary.id, deviceID: ordinary.deviceID, sequence: 1,
            captureID: ordinary.captureID, baseRevision: 0, mutation: .recapture,
            requestIdentity: .object(["sha256": .string("new")]))
        #expect(throws: SyncError.operationIDReused) { try server.apply(ordinaryRetry) }
        #expect(throws: SyncError.wrongDevice) {
            try server.reserveServiceWriter(deviceID: ordinary.deviceID, principalID: "service")
        }
        let device = UUID()
        try server.reserveServiceWriter(deviceID: device, principalID: "service")
        let operation = SyncOperation(
            deviceID: device, sequence: 1, captureID: UUID(), baseRevision: 0,
            mutation: .recapture, requestIdentity: .object(["sha256": .string("first")]))
        let receipt = try server.apply(operation, servicePrincipalID: "service")
        for identity in [nil, JSONValue.object(["sha256": .string("other")])] {
            let retry = SyncOperation(
                id: operation.id, deviceID: device, sequence: 1,
                captureID: operation.captureID, baseRevision: 0, mutation: .recapture,
                requestIdentity: identity)
            #expect(throws: SyncError.operationIDReused) {
                try server.apply(retry, servicePrincipalID: "service")
            }
        }
        #expect(try server.apply(operation, servicePrincipalID: "service") == receipt)
    }
}
