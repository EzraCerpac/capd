import Foundation
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
