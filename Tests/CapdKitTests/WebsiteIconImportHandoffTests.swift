import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdKit

@Suite(.serialized)
struct WebsiteIconImportHandoffTests {
    @Test(arguments: [false, true], [false, true])
    func activationCopiesLocalIconsIntoANewBoundStoreAndRollsBackFailedPublication(
        failPublication: Bool, supportsIcons: Bool
    ) async throws {
        let f = try IconHandoffFixture(supportsIcons: supportsIcons)
        defer { f.clean() }
        let before = try f.local.storedWebsiteIcons()
        let capture = try #require(
            try await f.local.reader.read { try Capture.fetchOne($0, key: f.captureID) })
        if failPublication {
            await #expect(throws: SyncHTTPError.unavailable) {
                try await MacLibrarySession.activate(
                    paths: f.paths, configuration: f.configuration, credentials: f.credentials,
                    transport: f.remote,
                    afterInstall: { _ in throw SyncHTTPError.unavailable })
            }
            #expect(try await f.local.reader.read { try StoreSync.binding(in: $0) } == nil)
            #expect(try f.local.storedWebsiteIcons() == before)
            #expect(try f.local.verifiedWebsiteIconData(before[0]) == f.localBytes)
            #expect(
                try await f.local.reader.read { try Capture.fetchOne($0, key: f.captureID) }
                    == capture)
            #expect(try MacSyncConfiguration.load(paths: f.paths) == nil)
            #expect(
                !FileManager.default.fileExists(
                    atPath: f.paths.assetsDirectory.appendingPathComponent("sync").path))
        }
        let bound = try await MacLibrarySession.activate(
            paths: f.paths, configuration: f.configuration, credentials: f.credentials,
            transport: f.remote)
        let icon = try #require(try bound.store.websiteIcon(for: f.url))
        #expect(icon.content == (supportsIcons ? f.targetContent : before[0].content))
        #expect(
            try bound.store.verifiedWebsiteIconData(icon)
                == (supportsIcons ? f.targetBytes : f.localBytes))
        #expect(try bound.store.syncClient?.websiteIcons() == (supportsIcons ? [icon] : []))
        #expect(try bound.store.syncClient?.pendingWebsiteIconOperations().isEmpty == true)
        if !supportsIcons {
            #expect(
                try await bound.store.reader.read { try !$0.tableExists("sync_website_icon_meta") })
            let reopened = try MacLibrarySession.open(
                paths: f.paths, credentials: f.credentials, transport: f.remote)
            #expect(try reopened.store.verifiedWebsiteIconData(icon) == f.localBytes)
        }
        #expect(
            try await bound.store.reader.read { try Capture.fetchOne($0, key: f.captureID) }
                == capture)
        #expect(
            try Data(
                contentsOf: f.paths.assetsDirectory
                    .appendingPathComponent(
                        "website-icons/\(BlobReference(data: f.localBytes).digest)"))
                == f.localBytes)
        _ = try bound.store.upsertCapture(
            Capture(kind: .text, selection: "New bound synthetic capture", createdAt: Date()))
        #expect(try bound.store.syncClient?.pendingOperations().map(\.sequence) == [1])
    }

    @Test func populatedUnboundSyncAssetsAreNotReboundDuringIconHandoff() async throws {
        let f = try IconHandoffFixture()
        defer { f.clean() }
        let directory = f.paths.assetsDirectory.appendingPathComponent("sync")
        let reference = try BlobStore(directory: directory).put(f.localBytes)
        let before = try f.local.storedWebsiteIcons()
        await #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
            try await MacLibrarySession.activate(
                paths: f.paths, configuration: f.configuration, credentials: f.credentials,
                transport: f.remote)
        }
        #expect(try await f.local.reader.read { try StoreSync.binding(in: $0) } == nil)
        #expect(try f.local.storedWebsiteIcons() == before)
        #expect(try MacSyncConfiguration.load(paths: f.paths) == nil)
        #expect(
            try Data(contentsOf: directory.appendingPathComponent(reference.digest)) == f.localBytes
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("library-owner").path))
    }

    @Test func corruptedLocalIconRefusesHandoffWithoutInstallingBindingOrConfig() async throws {
        let f = try IconHandoffFixture()
        defer { f.clean() }
        let file = f.paths.assetsDirectory.appendingPathComponent(
            "website-icons/\(BlobReference(data: f.localBytes).digest)")
        let invalid = Data("corrupted synthetic icon".utf8)
        try invalid.write(to: file)
        await #expect(throws: SyncError.invalidBlob) {
            try await MacLibrarySession.activate(
                paths: f.paths, configuration: f.configuration, credentials: f.credentials,
                transport: f.remote)
        }
        #expect(try await f.local.reader.read { try StoreSync.binding(in: $0) } == nil)
        #expect(try MacSyncConfiguration.load(paths: f.paths) == nil)
        #expect(try Data(contentsOf: file) == invalid)
        #expect(
            !FileManager.default.fileExists(
                atPath: f.paths.assetsDirectory.appendingPathComponent("sync").path))
    }
}

private struct IconHandoffFixture {
    let paths: StoragePaths
    let local: Store
    let captureID: Int64
    let configuration: MacSyncConfiguration
    let credentials = MemorySyncCredentialStore()
    let remote: IconHandoffRemote
    let url = "https://www.example.com/synthetic-path"
    let localBytes: Data
    let targetBytes: Data
    let targetContent: WebsiteIconContent

    init(supportsIcons: Bool = true) throws {
        paths = StoragePaths(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("capd-icon-handoff-\(UUID())").resolvingSymlinksInPath())
        local = try Store(paths: paths)
        let capture = try local.upsertCapture(
            Capture(
                kind: .link, url: url, title: "Synthetic link",
                contentHash: "synthetic-icon-handoff",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        ).capture
        let localID = try #require(capture.id)
        captureID = localID
        localBytes = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAmElEQVR4nO3QMREAIBDAsFeCHOTgfwMZGeiQvddZ+9yfjQ7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkB7np4RtCy3pxgAAAAASUVORK5CYII="
            ))
        targetBytes = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAmElEQVR4nO3QMREAIBDAsFeCHOTgfwMZGeiQvdc5e92fjQ7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkBrgA7QGqADtAboAK0BOkB7nzQRtFQATzMAAAAASUVORK5CYII="
            ))
        try WebsiteIconService.validatePNG(localBytes)
        try WebsiteIconService.validatePNG(targetBytes)
        let origin = try #require(WebsiteIconOrigin(url: url))
        let sourceBlob = try BlobStore(
            directory: paths.assetsDirectory.appendingPathComponent("website-icons")
        ).put(localBytes)
        let sourceContent = WebsiteIconContent(
            blob: sourceBlob, fetchedAt: Date(timeIntervalSinceReferenceDate: 12))
        let identity = UUID()
        try local.dbPool.write { db in
            try StoreSync.prepareIDs(db)
            try db.execute(
                sql: "INSERT INTO sync_capture_ids VALUES (?,?)",
                arguments: [localID, identity.uuidString])
            try db.execute(
                sql: "UPDATE website_icon_jobs SET content=?,state='succeeded' WHERE id=?",
                arguments: [try JSONEncoder().encode(sourceContent), origin.id])
        }
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.invalid/v1/sync")!, binding: binding,
            deviceID: UUID())
        configuration = MacSyncConfiguration(enrollment: enrollment)
        try credentials.save("synthetic-icon-handoff", for: enrollment)
        let server = try SyncServer(
            databaseURL: paths.root.appendingPathComponent("authority.sqlite"),
            blobDirectory: paths.root.appendingPathComponent("authority-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        let targetBlob = BlobReference(data: targetBytes)
        try server.upload(targetBlob, offset: 0, chunk: targetBytes, final: true)
        targetContent = WebsiteIconContent(
            blob: targetBlob, fetchedAt: Date(timeIntervalSinceReferenceDate: 24))
        let targetRecord = WebsiteIconRecord(origin: origin, revision: 0, content: targetContent)
        let snapshot = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: binding, sourceDeviceID: UUID(),
            captures: [StoreSync.snapshot(capture, id: identity)], websiteIcons: [targetRecord])
        _ = try server.importContentSnapshot(
            snapshot, preview: server.previewContentSnapshotImport(snapshot))
        remote = IconHandoffRemote(
            binding: binding, deviceID: enrollment.deviceID, server: server,
            supportsIcons: supportsIcons)
    }

    func clean() { try? FileManager.default.removeItem(at: paths.root) }
}

private struct IconHandoffRemote: AsyncSyncTransport, SyncAuthorizer {
    let binding: SyncLibraryBinding
    let deviceID: UUID
    let server: SyncServer
    let supportsIcons: Bool

    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        guard bearerCredential == "synthetic-icon-handoff" else { return nil }
        return SyncPrincipal(
            serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: deviceID)
    }

    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        let response = SyncHTTPHandler(
            serviceID: binding.serviceID, authorizer: self, server: { _ in server }
        ).handle(request)
        guard !supportsIcons else { return response }
        var json = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        json.removeValue(forKey: "websiteIconContractVersion")
        return SyncHTTPResponse(
            status: response.status, headers: response.headers,
            body: try JSONSerialization.data(withJSONObject: json, options: .sortedKeys))
    }
}
