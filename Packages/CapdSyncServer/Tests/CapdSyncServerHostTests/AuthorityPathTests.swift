import CapdSync
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import CapdSyncServerHost

@Suite("Authority storage boundaries")
struct AuthorityPathTests {
    @Test(
        arguments: [
            "authority.sqlite", "authority.sqlite-wal", "authority.sqlite-shm",
            "authority.sqlite-journal",
        ], [false, true])
    func databaseAndSidecarSymlinksAreRejectedBeforeSQLiteOpens(name: String, dangling: Bool)
        async throws
    {
        let fixture = try AuthorityPathFixture()
        defer { fixture.clean() }
        let authority = try Authority(
            configurationURL: fixture.configuration, dataDirectory: fixture.data)
        let library = fixture.data.appendingPathComponent(fixture.library.uuidString.lowercased())
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let database = library.appendingPathComponent("authority.sqlite")
        let sentinel = Data("untouched synthetic file".utf8)
        let originalDatabase: Data?
        if name != "authority.sqlite" {
            _ = try SyncServer(
                databaseURL: database,
                blobDirectory: fixture.root.appendingPathComponent("seed-blobs"),
                libraryID: fixture.library, serviceID: fixture.service)
            let checkpoint = try DatabaseQueue(path: database.path)
            try await checkpoint.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            try checkpoint.close()
            originalDatabase = try Data(contentsOf: database)
        } else {
            originalDatabase = nil
        }
        let target = fixture.root.appendingPathComponent("outside-library.sqlite")
        if !dangling { try sentinel.write(to: target) }
        let link = library.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: link.path) {
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(await authority.handle(try fixture.baselineRequest()).status == 503)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        if dangling {
            #expect(!FileManager.default.fileExists(atPath: target.path))
        } else {
            #expect(try Data(contentsOf: target) == sentinel)
        }
        if let originalDatabase {
            #expect(try Data(contentsOf: database) == originalDatabase)
        }
        #expect(
            !FileManager.default.fileExists(atPath: library.appendingPathComponent("blobs").path))
    }

    @Test(arguments: [UInt64(1_025), UInt64(1_073_741_824)])
    func oversizedAndSparseServiceMarkersAreRejectedWithoutReadingContents(size: UInt64) throws {
        let fixture = try AuthorityPathFixture()
        defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.data, withIntermediateDirectories: true)
        let marker = fixture.data.appendingPathComponent("service.json")
        let identity = try JSONEncoder().encode(fixture.service)
        try identity.write(to: marker)
        let file = try FileHandle(forWritingTo: marker)
        try file.truncate(atOffset: size)
        try file.close()
        #expect(throws: HostError.self) {
            try Authority(configurationURL: fixture.configuration, dataDirectory: fixture.data)
        }
        let reopened = try FileHandle(forReadingFrom: marker)
        defer { try? reopened.close() }
        #expect(try reopened.read(upToCount: identity.count) == identity)
        #expect(try marker.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(size))
    }

    @Test func serviceMarkerAtBoundStillLoads() throws {
        let fixture = try AuthorityPathFixture()
        defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.data, withIntermediateDirectories: true)
        let marker = fixture.data.appendingPathComponent("service.json")
        var bytes = try JSONEncoder().encode(fixture.service)
        bytes.append(Data(repeating: 32, count: 1_024 - bytes.count))
        try bytes.write(to: marker)
        _ = try Authority(configurationURL: fixture.configuration, dataDirectory: fixture.data)
        #expect(try Data(contentsOf: marker) == bytes)
    }
}

private struct AuthorityPathFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = UUID(), library = UUID(), device = UUID()
    let credential = String(repeating: "a", count: 64)
    var configuration: URL { root.appendingPathComponent("config.json") }
    var data: URL { root.appendingPathComponent("data") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }
            .joined()
        let configuration: [String: Any] = [
            "serviceID": service.uuidString,
            "enrollments": [
                [
                    "libraryID": library.uuidString, "deviceID": device.uuidString,
                    "credentialSHA256": digest, "revoked": false,
                ]
            ],
        ]
        try JSONSerialization.data(withJSONObject: configuration).write(to: self.configuration)
    }

    func baselineRequest() throws -> SyncHTTPRequest {
        SyncHTTPRequest(
            method: "POST", path: "/v1/sync",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(credential)"],
            body: try JSONEncoder().encode(
                SyncHTTPEnvelope(
                    expectedServiceID: service, expectedLibraryID: library,
                    expectedDeviceID: device, action: .baseline)))
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
