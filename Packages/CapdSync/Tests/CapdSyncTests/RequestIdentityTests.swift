import Foundation
import GRDB
import Testing

@testable import CapdSync

struct RequestIdentityTests {
    @Test func operationsWithoutRequestIdentityStillDecodeAndReplay() throws {
        let operation = SyncOperation(
            deviceID: UUID(), sequence: 1, captureID: UUID(), baseRevision: 0,
            mutation: .recapture)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as? [String: Any])
        object.removeValue(forKey: "requestIdentity")
        let decoded = try JSONDecoder().decode(
            SyncOperation.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == operation)
        #expect(decoded.requestIdentity == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("blobs"))
        let receipt = try server.apply(decoded)
        #expect(try server.apply(decoded) == receipt)
    }

    @Test func servicePrincipalCannotRotateItsDurableWriterDeviceAfterReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("authority.sqlite")
        let blobs = root.appendingPathComponent("blobs")
        let server = try SyncServer(databaseURL: database, blobDirectory: blobs)
        let device = UUID()
        try server.reserveServiceWriter(deviceID: device, principalID: "service-principal")
        let operation = SyncOperation(
            deviceID: device, sequence: 1, captureID: UUID(), baseRevision: 0, mutation: .recapture)
        let receipt = try server.apply(operation, servicePrincipalID: "service-principal")
        let reopened = try SyncServer(databaseURL: database, blobDirectory: blobs)
        for _ in 0..<3 {
            #expect(throws: SyncError.wrongDevice) {
                try reopened.reserveServiceWriter(
                    deviceID: UUID(), principalID: "service-principal")
            }
        }
        #expect(throws: SyncError.wrongDevice) {
            try reopened.reserveServiceWriter(deviceID: device, principalID: "other-principal")
        }
        try reopened.reserveServiceWriter(deviceID: device, principalID: "service-principal")
        #expect(try reopened.apply(operation, servicePrincipalID: "service-principal") == receipt)
        let next = SyncOperation(
            deviceID: device, sequence: 2, captureID: UUID(), baseRevision: 0, mutation: .recapture)
        _ = try reopened.apply(next, servicePrincipalID: "service-principal")
        #expect(try reopened.baseline().deviceSequences == [device: 2])
        let reader = try DatabaseQueue(path: database.path)
        #expect(
            try reader.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_service_writers")
            } == 1)
    }

    @Test func concurrentReservationsKeepOneDevicePerPrincipal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("authority.sqlite")
        let blobs = root.appendingPathComponent("blobs")
        let servers = try (0..<2).map { _ in
            try SyncServer(databaseURL: database, blobDirectory: blobs)
        }
        let devices = [UUID(), UUID()]
        let successes = await withTaskGroup(of: Bool.self) { group in
            for (server, device) in zip(servers, devices) {
                group.addTask {
                    do {
                        try server.reserveServiceWriter(deviceID: device, principalID: "principal")
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        #expect(successes == 1)
        let reader = try DatabaseQueue(path: database.path)
        #expect(
            try await reader.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_service_writers")
            } == 1)
    }

    @Test func requestIdentityParticipatesInReceiptEquality() throws {
        let id = UUID()
        let device = UUID()
        let capture = UUID()
        func operation(_ identity: JSONValue) -> SyncOperation {
            SyncOperation(
                id: id, deviceID: device, sequence: 1, captureID: capture, baseRevision: 0,
                mutation: .recapture, requestIdentity: identity)
        }
        let explicit = operation(.object(["rating": .number(3)]))
        let omitted = operation(.object([:]))
        #expect(explicit != omitted)
        #expect(
            try JSONDecoder().decode(SyncOperation.self, from: JSONEncoder().encode(explicit))
                == explicit)
    }
}
