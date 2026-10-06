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
            #expect(try await f.local.reader.read { try !$0.tableExists("sync_website_icon_meta") })
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
        #expect(try bound.store.syncClient?.websiteIcons() == [icon])
        #expect(
            try bound.store.syncClient?.pendingWebsiteIconOperations().count
                == (supportsIcons ? 0 : 1))
        if !supportsIcons {
            #expect(
                try await bound.store.reader.read { try $0.tableExists("sync_website_icon_meta") })
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

    @Test(arguments: [false, true], [false, true])
    func legacyHandoffPublishesPreservedIconsAfterUpgradeWithoutRefetch(
        targetExisting: Bool, lostAcknowledgement: Bool
    ) async throws {
        let f = try IconHandoffFixture(supportsIcons: false, targetExisting: targetExisting)
        defer { f.clean() }
        let original = try #require(try f.local.websiteIcon(for: f.url))
        let bound = try await MacLibrarySession.activate(
            paths: f.paths, configuration: f.configuration, credentials: f.credentials,
            transport: f.remote)
        let client = try #require(bound.store.syncClient)
        let pending = try client.pendingWebsiteIconOperations()
        #expect(pending.count == 1)
        #expect(pending.first?.sequence == 1 && pending.first?.baseRevision == 0)
        #expect(pending.first?.mutation == .upsert(original.content!))
        #expect(try client.websiteIconCursor() == 0)
        #expect(try !bound.store.websiteIconsEnabled())
        #expect(
            try await bound.store.reader.read {
                try String.fetchOne($0, sql: "SELECT state FROM website_icon_jobs")
            } == "succeeded")
        let fetches = DeferredImportFetchCounter()
        let service = WebsiteIconService(
            store: bound.store,
            fetch: { _ in
                fetches.increment()
                throw SyncHTTPError.unavailable
            })
        #expect(try await !service.processNext())
        #expect(fetches.value == 0)
        await #expect(throws: SyncHTTPError.unsupportedVersion) {
            try await client.pushWebsiteIcons(
                to: f.remote, credential: { "synthetic-icon-handoff" })
        }
        #expect(try client.pendingWebsiteIconOperations() == pending)
        #expect(try bound.store.claimNextWebsiteIcon() == nil)
        _ = try CaptureService(store: bound.store).ingest(
            CaptureRequest(text: "Retained offline capture"))
        let capturePending = try client.pendingOperations()
        let captureCursor = try client.cursor()
        let reopened = try MacLibrarySession.open(
            paths: f.paths, credentials: f.credentials, transport: f.remote)
        let restarted = try #require(reopened.store.syncClient)
        #expect(try restarted.pendingWebsiteIconOperations() == pending)
        let upgraded = IconHandoffRemote(
            binding: f.remote.binding, deviceID: f.remote.deviceID, server: f.remote.server,
            supportsIcons: true)
        if lostAcknowledgement, !pending.isEmpty {
            let lost = LostIconHandoffAcknowledgement(base: upgraded)
            await #expect(throws: SyncHTTPError.unavailable) {
                try await restarted.pushWebsiteIcons(
                    to: lost, credential: { "synthetic-icon-handoff" })
            }
            #expect(try restarted.pendingWebsiteIconOperations() == pending)
        }
        try await restarted.pushWebsiteIcons(to: upgraded, credential: { "synthetic-icon-handoff" })
        #expect(try restarted.pendingWebsiteIconOperations().isEmpty)
        #expect(try !reopened.store.websiteIconsEnabled())
        #expect(fetches.value == 0)
        #expect(try restarted.pendingOperations() == capturePending)
        #expect(try restarted.cursor() == captureCursor)
        #expect(try upgraded.server.baseline().deviceSequences[client.deviceID] == nil)
        let received = try #require(try upgraded.server.websiteIconBaseline().records.first)
        #expect(received.content == (targetExisting ? f.targetContent : original.content))
        #expect(try upgraded.server.websiteIconBaseline().deviceSequences[client.deviceID] == 1)
        try reopened.store.refreshWebsiteIconsFromSync()
        #expect(try reopened.store.websiteIcon(for: f.url)?.content == received.content)
        let peerID = UUID()
        let peer = try SyncClient(
            databaseURL: f.paths.root.appendingPathComponent("peer.sqlite"),
            blobDirectory: f.paths.root.appendingPathComponent("peer-blobs"), deviceID: peerID,
            binding: upgraded.binding)
        let peerRemote = IconHandoffRemote(
            binding: upgraded.binding, deviceID: peerID, server: upgraded.server,
            supportsIcons: true)
        try await peer.pullWebsiteIcons(from: peerRemote, credential: { "synthetic-icon-handoff" })
        let offline = try #require(try peer.websiteIcon(originID: received.id))
        #expect(offline == received)
        #expect(
            try peer.blobs.read(offline.content!.blob)
                == (targetExisting ? f.targetBytes : f.localBytes))
        #expect(
            try Data(
                contentsOf: f.paths.assetsDirectory.appendingPathComponent(
                    "website-icons/\(BlobReference(data: f.localBytes).digest)")) == f.localBytes)
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

    init(supportsIcons: Bool = true, targetExisting: Bool = true) throws {
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
            captures: [StoreSync.snapshot(capture, id: identity)],
            websiteIcons: targetExisting ? [targetRecord] : nil)
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

private final class LostIconHandoffAcknowledgement: AsyncSyncTransport, @unchecked Sendable {
    let base: IconHandoffRemote
    private let lock = NSLock()
    private var lost = false
    var binding: SyncLibraryBinding { base.binding }
    var deviceID: UUID { base.deviceID }
    init(base: IconHandoffRemote) { self.base = base }
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        let response = try await base.send(request)
        let action = try JSONDecoder().decode(SyncHTTPEnvelope.self, from: request.body).action
        if case .applyWebsiteIcon = action {
            let drop = lock.withLock {
                if lost { return false }
                lost = true
                return true
            }
            if drop { throw SyncHTTPError.unavailable }
        }
        return response
    }
}

private final class DeferredImportFetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
