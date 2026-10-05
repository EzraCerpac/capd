import CapdSync
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import CapdSyncServerHost

@Suite("Authority cache and lock limits")
struct AuthorityResourceTests {
    @Test func cacheEvictsLeastRecentlyUsedLibraryAndReopensItsDurableState() async throws {
        let fixture = try AuthorityResourceFixture(count: Authority.maximumCachedLibraries + 1)
        defer { fixture.clean() }
        let authority = try Authority(configurationURL: fixture.config, dataDirectory: fixture.data)
        let capture = SharedCapture(
            source: CaptureSource(kind: .text, selection: "saved before eviction"))
        let operation = SyncOperation(
            deviceID: fixture.devices[1], sequence: 1, captureID: capture.id,
            baseRevision: 0, mutation: .create(capture))
        #expect(
            await authority.handle(try fixture.request(1, action: .apply(operation))).status == 200)
        for index in 0..<Authority.maximumCachedLibraries {
            #expect(await authority.handle(try fixture.request(index)).status == 200)
        }
        #expect(await authority.handle(try fixture.request(0)).status == 200)
        #expect(
            await authority.handle(try fixture.request(Authority.maximumCachedLibraries)).status
                == 200)
        let cached = await authority.cachedLibraryIDs()
        #expect(cached.count == Authority.maximumCachedLibraries)
        #expect(cached.contains(fixture.libraries[0]))
        #expect(!cached.contains(fixture.libraries[1]))
        let reopened = await authority.handle(try fixture.request(1))
        #expect(reopened.status == 200)
        let reply = try JSONDecoder().decode(SyncHTTPReply.self, from: reopened.body)
        guard case .baseline(let baseline) = reply.result else {
            Issue.record("Expected a baseline after reopening the evicted authority")
            return
        }
        #expect(baseline.captures.map(\.id) == [capture.id])
        #expect(baseline.deviceSequences[fixture.devices[1]] == 1)
        #expect(await authority.cachedLibraryIDs().count == Authority.maximumCachedLibraries)
    }

    @Test func configurationRotationCannotGrowCacheWithoutBound() async throws {
        let fixture = try AuthorityResourceFixture(count: Authority.maximumCachedLibraries + 5)
        defer { fixture.clean() }
        let authority = try Authority(configurationURL: fixture.config, dataDirectory: fixture.data)
        for index in fixture.libraries.indices {
            try fixture.writeConfiguration(indices: [index])
            #expect(await authority.handle(try fixture.request(index)).status == 200)
            #expect(await authority.cachedLibraryIDs().count <= Authority.maximumCachedLibraries)
        }
        #expect(await authority.handle(try fixture.request(0)).status == 401)
    }

    @Test(arguments: ["nonempty", "hardlink", "fifo", "directory"])
    func boundDirectoryRejectsUnsafeOpenedLock(kind: String) throws {
        let fixture = try AuthorityResourceFixture(count: 1)
        defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.data, withIntermediateDirectories: true)
        try JSONEncoder().encode(fixture.service).write(
            to: fixture.data.appendingPathComponent("service.json"))
        let lock = fixture.data.appendingPathComponent(".server.lock")
        let outside = fixture.root.appendingPathComponent("outside-empty-file")
        switch kind {
        case "nonempty": try Data("not a lock".utf8).write(to: lock)
        case "hardlink":
            try Data().write(to: outside)
            try FileManager.default.linkItem(at: outside, to: lock)
        case "fifo": #expect(mkfifo(lock.path, 0o600) == 0)
        default:
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        }
        #expect(throws: HostError.self) {
            try Authority(configurationURL: fixture.config, dataDirectory: fixture.data)
        }
        if kind == "hardlink" { #expect(try Data(contentsOf: outside).isEmpty) }
        try FileManager.default.removeItem(at: lock)
        try Data().write(to: lock)
        _ = try Authority(configurationURL: fixture.config, dataDirectory: fixture.data)
    }
}

private struct AuthorityResourceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = UUID()
    let libraries: [UUID]
    let devices: [UUID]
    let credentials: [String]
    var config: URL { root.appendingPathComponent("config.json") }
    var data: URL { root.appendingPathComponent("data") }

    init(count: Int) throws {
        libraries = (0..<count).map { _ in UUID() }
        devices = (0..<count).map { _ in UUID() }
        credentials = (0..<count).map { String(format: "%064x", $0 + 1) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeConfiguration(indices: Array(libraries.indices))
    }

    func writeConfiguration(indices: [Int]) throws {
        let rows: [[String: Any]] = indices.map { index in
            [
                "libraryID": libraries[index].uuidString, "deviceID": devices[index].uuidString,
                "credentialSHA256": SHA256.hash(data: Data(credentials[index].utf8)).map {
                    String(format: "%02x", $0)
                }.joined(), "revoked": false,
            ]
        }
        try JSONSerialization.data(withJSONObject: [
            "serviceID": service.uuidString, "enrollments": rows,
        ])
        .write(to: config, options: .atomic)
    }

    func request(_ index: Int, action: SyncHTTPAction = .baseline) throws -> SyncHTTPRequest {
        SyncHTTPRequest(
            method: "POST", path: "/v1/sync",
            headers: [
                "Content-Type": "application/json", "Authorization": "Bearer \(credentials[index])",
            ],
            body: try JSONEncoder().encode(
                SyncHTTPEnvelope(
                    expectedServiceID: service, expectedLibraryID: libraries[index],
                    expectedDeviceID: devices[index], action: action)))
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
