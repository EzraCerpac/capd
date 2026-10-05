import CapdSync
import CryptoKit
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import Testing

@testable import CapdSyncServerHost

@Suite("Standalone sync host")
struct HostTests {
    @Test func digestEnrollmentReloadAndServicePin() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.clean() }
        let authorizer = ConfigurationAuthorizer(
            configurationURL: fixture.config, serviceID: fixture.service)
        #expect(
            try authorizer.authorize(bearerCredential: fixture.credential)?.deviceID
                == fixture.device)
        #expect(try authorizer.authorize(bearerCredential: "short") == nil)
        #expect(
            try authorizer.authorize(bearerCredential: String(repeating: "b", count: 64)) == nil)
        try fixture.write(revoked: true)
        #expect(try authorizer.authorize(bearerCredential: fixture.credential) == nil)
        try fixture.write(service: UUID())
        #expect(throws: HostError.self) {
            try authorizer.authorize(bearerCredential: fixture.credential)
        }
        try Data("not JSON".utf8).write(to: fixture.config)
        #expect(throws: (any Error).self) {
            try authorizer.authorize(bearerCredential: fixture.credential)
        }
    }

    @Test func rejectsMalformedDuplicateAndEmptyEnrollment() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.clean() }
        for change in [
            "placeholder", "duplicateCredential", "duplicateDevice", "empty", "unknown", "zero",
        ] {
            var object = try fixture.object()
            var rows = object["enrollments"] as! [[String: Any]]
            switch change {
            case "placeholder": rows[0]["credentialSHA256"] = "REPLACE_WITH_SHA256_DIGEST"
            case "duplicateCredential":
                rows.append(rows[0].merging(["deviceID": UUID().uuidString]) { _, new in new })
            case "duplicateDevice":
                rows.append(
                    rows[0].merging(["credentialSHA256": String(repeating: "b", count: 64)]) {
                        _, new in new
                    })
            case "empty": rows = []
            case "unknown": rows[0]["plaintextCredential"] = "forbidden"
            default: object["serviceID"] = "00000000-0000-0000-0000-000000000000"
            }
            object["enrollments"] = rows
            try JSONSerialization.data(withJSONObject: object).write(to: fixture.config)
            #expect(throws: (any Error).self) { try HostConfiguration.read(fixture.config) }
        }
    }

    @Test func duplicateHTTPHeadersAreNotFlattened() {
        var fields = HTTPFields()
        fields.append(HTTPField(name: .authorization, value: "Bearer A"))
        fields.append(HTTPField(name: .authorization, value: "Bearer B"))
        #expect(HostHTTP.headers(fields) == nil)
        fields = [.authorization: "Bearer A", .contentType: "application/json"]
        #expect(HostHTTP.headers(fields)?["authorization"] == "Bearer A")
        fields.append(HTTPField(name: .contentType, value: "application/json"))
        #expect(HostHTTP.headers(fields) == nil)
    }

    @Test func rootBindingAndPersistence() async throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.clean() }
        let authority = try Authority(configurationURL: fixture.config, dataDirectory: fixture.data)
        func request(_ action: SyncHTTPAction) throws -> SyncHTTPRequest {
            SyncHTTPRequest(
                method: "POST", path: "/v1/sync",
                headers: [
                    "Content-Type": "application/json",
                    "Authorization": "Bearer \(fixture.credential)",
                ],
                body: try JSONEncoder().encode(
                    SyncHTTPEnvelope(
                        expectedServiceID: fixture.service,
                        expectedLibraryID: fixture.library, expectedDeviceID: fixture.device,
                        action: action)))
        }
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "synthetic"))
        let op = SyncOperation(
            deviceID: fixture.device, sequence: 1, captureID: capture.id,
            baseRevision: 0, mutation: .create(capture))
        let first = await authority.handle(try request(.apply(op)))
        let again = await authority.handle(try request(.apply(op)))
        #expect(first.status == 200)
        #expect(first.body == again.body)
        #expect(await authority.handle(try request(.baseline)).status == 200)
        try fixture.write(service: UUID())
        #expect(await authority.handle(try request(.baseline)).status == 503)
        #expect(throws: HostError.self) {
            try Authority(configurationURL: fixture.config, dataDirectory: fixture.data)
        }
    }

    @Test func refusesUnownedNonemptyStorageWithoutClaimingIt() throws {
        let fixture = try ConfigurationFixture()
        defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.data, withIntermediateDirectories: true)
        let existing = fixture.data.appendingPathComponent("existing.sqlite")
        try Data("unrelated".utf8).write(to: existing)
        #expect(throws: HostError.self) {
            try Authority(configurationURL: fixture.config, dataDirectory: fixture.data)
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.data.path) == [
                "existing.sqlite"
            ])
        #expect(try Data(contentsOf: existing) == Data("unrelated".utf8))
    }

    @Test func bodyFailuresDistinguishLimitsFromTransport() {
        #expect(HostHTTP.bodyFailure(NIOTooManyBytesError(maxBytes: 1)).status.code == 413)
        #expect(HostHTTP.bodyFailure(CancellationError()).status.code == 503)
    }

    @Test func admissionIsBounded() async {
        let admission = Admission()
        for _ in 0..<8 { #expect(await admission.acquire()) }
        #expect(await admission.acquire() == false)
        await admission.release()
        #expect(await admission.acquire())
    }
}

private struct ConfigurationFixture {
    let root: URL
    let config: URL
    let data: URL
    let service = UUID()
    let library = UUID()
    let device = UUID()
    let credential = String(repeating: "a", count: 64)
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-host-test-\(UUID())")
        config = root.appendingPathComponent("config.json")
        data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write()
    }
    func object(service: UUID? = nil, revoked: Bool = false) throws -> [String: Any] {
        [
            "serviceID": (service ?? self.service).uuidString,
            "enrollments": [
                [
                    "libraryID": library.uuidString, "deviceID": device.uuidString,
                    "credentialSHA256": SHA256.hash(data: Data(credential.utf8)).map {
                        String(format: "%02x", $0)
                    }.joined(),
                    "revoked": revoked,
                ]
            ],
        ]
    }
    func write(service: UUID? = nil, revoked: Bool = false) throws {
        try JSONSerialization.data(withJSONObject: object(service: service, revoked: revoked))
            .write(to: config, options: .atomic)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
