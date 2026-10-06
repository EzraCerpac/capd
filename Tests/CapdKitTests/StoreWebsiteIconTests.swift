import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import CapdKit
@testable import CapdSync

@Suite("Website icon queue")
struct StoreWebsiteIconTests {
    @Test(arguments: [false, true], [false, true])
    func orphanSweepPreservesManagedIcons(unreferenced: Bool, throughAlias: Bool) async throws {
        try await withIconPathsAsync { paths in
            let store = try Store(paths: paths)
            let capture = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org/sweep", fetchBody: false)
            ).capture
            try store.setWebsiteIconsEnabled(true)
            let bytes = try iconPNG()
            #expect(
                try await WebsiteIconService(store: store, fetch: { _ in .normalizedPNG(bytes) })
                    .processNext())
            let record = try #require(try store.websiteIcon(for: "https://example.org"))
            let blob = try #require(record.content?.blob)
            let icon = paths.assetsDirectory.appendingPathComponent("website-icons/" + blob.digest)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let old = now.addingTimeInterval(-7_200)
            let manager = FileManager.default
            try manager.setAttributes([.modificationDate: old], ofItemAtPath: icon.path)
            if throughAlias {
                try manager.createSymbolicLink(
                    at: paths.assetsDirectory.appendingPathComponent("icon-alias.png"),
                    withDestinationURL: icon)
            }
            for path in ["capture-orphan.png", "website-icons-extra/orphan.png", "fresh.png"] {
                let url = paths.assetURL(forRelativePath: path)
                try manager.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("synthetic capture asset".utf8).write(to: url)
                try manager.setAttributes(
                    [.modificationDate: path == "fresh.png" ? now : old], ofItemAtPath: url.path)
            }
            if unreferenced { _ = try store.deleteCaptures(ids: [try #require(capture.id)]) }
            let before = try await store.reader.read {
                try Data.fetchOne(
                    $0, sql: "SELECT content FROM website_icon_jobs WHERE id=?",
                    arguments: [record.id])
            }

            let sweep = try store.sweepOrphanAssets(now: now)

            #expect(sweep.removedPaths == ["capture-orphan.png", "website-icons-extra/orphan.png"])
            #expect(sweep.missingCaptureIDs.isEmpty)
            #expect(try store.verifiedWebsiteIconData(record) == bytes)
            #expect(try store.websiteIconsEnabled())
            #expect(try store.claimNextWebsiteIcon() == nil)
            #expect(
                try await store.reader.read {
                    try Data.fetchOne(
                        $0, sql: "SELECT content FROM website_icon_jobs WHERE id=?",
                        arguments: [record.id])
                } == before)
            #expect(
                try await store.reader.read {
                    try String.fetchOne(
                        $0, sql: "SELECT state FROM website_icon_jobs WHERE id=?",
                        arguments: [record.id])
                } == "succeeded")
            #expect(manager.fileExists(atPath: paths.assetURL(forRelativePath: "fresh.png").path))
            if throughAlias {
                #expect(
                    manager.fileExists(
                        atPath: paths.assetsDirectory.appendingPathComponent(
                            "icon-alias.png"
                        ).path))
            }
            if unreferenced {
                _ = try CaptureService(store: store).ingest(
                    CaptureRequest(url: "https://example.org/restored", fetchBody: false))
            }
            #expect(try store.websiteIcon(for: "https://example.org") == record)
        }
    }

    @Test func policyAndOrigins() throws {
        try withIconPaths { paths in
            let store = try Store(paths: paths)
            let captures = CaptureService(store: store)
            for url in [
                "https://Example.org/a?q=1", "https://example.org/b", "https://www.example.org/c",
                "http://example.org/d", "https://localhost/e",
            ] {
                _ = try captures.ingest(CaptureRequest(url: url, fetchBody: false))
            }
            #expect(try !store.websiteIconsEnabled())
            #expect(try store.claimNextWebsiteIcon() == nil)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM website_icon_jobs")
                } == 2)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM capture_icon_origins")
                } == 3)
            try store.setWebsiteIconsEnabled(true)
            let first = try #require(try store.claimNextWebsiteIcon())
            let second = try #require(try store.claimNextWebsiteIcon())
            #expect(first.origin != second.origin)
            #expect(try store.claimNextWebsiteIcon() == nil)
        }
    }

    @Test func savedIconSurvivesReopenAndCoalesces() async throws {
        try await withIconPathsAsync { paths in
            let store = try Store(paths: paths)
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org/a", fetchBody: false))
            try store.setWebsiteIconsEnabled(true)
            let bytes = try iconPNG()
            let service = WebsiteIconService(store: store, fetch: { _ in .normalizedPNG(bytes) })
            #expect(try await service.processNext())
            #expect(try await !service.processNext())
            let record = try #require(try store.websiteIcon(for: "https://example.org/other"))
            #expect(try store.verifiedWebsiteIconData(record) == bytes)
            #expect(record.content?.blob == BlobReference(data: bytes))
            #expect(
                !FileManager.default.fileExists(
                    atPath: paths.assetsDirectory.appendingPathComponent("sync").path))
            let reopened = try Store(paths: paths)
            #expect(try reopened.websiteIconsEnabled())
            #expect(try reopened.websiteIcon(for: "https://example.org") == record)
            #expect(try reopened.claimNextWebsiteIcon() == nil)
            #expect(try await reopened.reader.read(Store.websiteIconRecords(in:)) == [record])
        }
    }

    @Test(arguments: [false, true]) func dueTimePersists(missing: Bool) async throws {
        try await withIconPathsAsync { paths in
            let store = try Store(paths: paths)
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org", fetchBody: false))
            try store.setWebsiteIconsEnabled(true)
            let time = Date(timeIntervalSince1970: 1000)
            let service = WebsiteIconService(
                store: store,
                fetch: { _ in
                    if missing { return .missing }
                    throw URLError(.notConnectedToInternet)
                }, now: { time })
            if missing {
                #expect(try await service.processNext())
            } else {
                await #expect(throws: URLError.self) { try await service.processNext() }
            }
            let reopened = try Store(paths: paths)
            let delay = missing ? FaviconPolicy.missTTL : 30
            #expect(
                try reopened.claimNextWebsiteIcon(now: time.addingTimeInterval(delay - 1)) == nil)
            #expect(try reopened.claimNextWebsiteIcon(now: time.addingTimeInterval(delay)) != nil)
        }
    }

    @Test func restartRecoversClaimWithoutReplayingOldToken() throws {
        try withIconPaths { paths in
            let store = try Store(paths: paths)
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org", fetchBody: false))
            try store.setWebsiteIconsEnabled(true)
            let time = Date(timeIntervalSince1970: 1000)
            let old = try #require(try store.claimNextWebsiteIcon(now: time))
            let reopened = try Store(paths: paths)
            #expect(
                try reopened.reclaimStaleWebsiteIconClaims(now: time.addingTimeInterval(59)) == 0)
            #expect(
                try reopened.reclaimStaleWebsiteIconClaims(now: time.addingTimeInterval(60)) == 1)
            let current = try #require(
                try reopened.claimNextWebsiteIcon(now: time.addingTimeInterval(60)))
            #expect(current.token != old.token)
            #expect(try !reopened.finishWebsiteIcon(old, content: nil, missing: true, now: time))
        }
    }

    @Test(arguments: ["disable", "delete", "cancel"])
    func awaitedResultCannotPublishAfterInvalidation(action: String) async throws {
        try await withIconPathsAsync { paths in
            let store = try Store(paths: paths)
            let capture = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org", fetchBody: false)
            ).capture
            try store.setWebsiteIconsEnabled(true)
            let suspended = IconFetchLatch(bytes: try iconPNG())
            let service = WebsiteIconService(store: store, fetch: { _ in await suspended.fetch() })
            let task = Task { try await service.processNext() }
            await suspended.waitUntilStarted()
            if action == "disable" {
                try store.setWebsiteIconsEnabled(false)
                try store.setWebsiteIconsEnabled(true)
            } else if action == "delete" {
                _ = try store.deleteCaptures(ids: [try #require(capture.id)])
            } else {
                task.cancel()
            }
            await suspended.release()
            if action == "cancel" {
                await #expect(throws: CancellationError.self) { try await task.value }
            } else {
                _ = try await task.value
            }
            #expect(try store.websiteIcon(for: "https://example.org") == nil)
            #expect(
                try await store.reader.read {
                    try Int.fetchOne(
                        $0, sql: "SELECT COUNT(*) FROM website_icon_jobs WHERE content IS NOT NULL")
                } == 0)
        }
    }

    @Test func otherReferenceSurvivesDeleteAndRestoreReusesAsset() async throws {
        try await withIconPathsAsync { paths in
            let store = try Store(paths: paths)
            let captures = CaptureService(store: store)
            let first = try captures.ingest(
                CaptureRequest(url: "https://example.org/a", fetchBody: false)
            ).capture
            let second = try captures.ingest(
                CaptureRequest(url: "https://example.org/b", fetchBody: false)
            ).capture
            try store.setWebsiteIconsEnabled(true)
            let suspended = IconFetchLatch(bytes: try iconPNG())
            let service = WebsiteIconService(store: store, fetch: { _ in await suspended.fetch() })
            let task = Task { try await service.processNext() }
            await suspended.waitUntilStarted()
            _ = try store.deleteCaptures(ids: [try #require(first.id)])
            await suspended.release()
            #expect(try await task.value)
            let record = try #require(try store.websiteIcon(for: "https://example.org/b"))
            _ = try store.deleteCaptures(ids: [try #require(second.id)])
            #expect(try store.storedWebsiteIcons().isEmpty)
            _ = try captures.ingest(
                CaptureRequest(url: "https://example.org/restored", fetchBody: false))
            #expect(try store.websiteIcon(for: "https://example.org/restored") == record)
            #expect(try store.claimNextWebsiteIcon() == nil)
        }
    }

    @Test(arguments: [false, true]) func failedRefreshRetainsPriorIcon(missing: Bool) async throws {
        try await withIconPathsAsync { paths in
            let store = try Store(paths: paths)
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org", fetchBody: false))
            try store.setWebsiteIconsEnabled(true)
            let bytes = try iconPNG()
            #expect(
                try await WebsiteIconService(store: store, fetch: { _ in .normalizedPNG(bytes) })
                    .processNext())
            let previous = try #require(try store.websiteIcon(for: "https://example.org"))
            try await store.dbPool.write {
                try $0.execute(sql: "UPDATE website_icon_jobs SET state='pending'")
            }
            let service = WebsiteIconService(
                store: store,
                fetch: { _ in
                    if missing { return .missing }
                    throw URLError(.timedOut)
                })
            if missing {
                #expect(try await service.processNext())
            } else {
                await #expect(throws: URLError.self) { try await service.processNext() }
            }
            #expect(try store.websiteIcon(for: "https://example.org") == previous)
            #expect(try store.verifiedWebsiteIconData(previous) == bytes)
        }
    }

    @Test func invalidPNGIsRetried() async throws {
        try await withIconPathsAsync { paths in
            let store = try Store(paths: paths)
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org", fetchBody: false))
            try store.setWebsiteIconsEnabled(true)
            let service = WebsiteIconService(
                store: store, fetch: { _ in .normalizedPNG(Data("not an icon".utf8)) })
            await #expect(throws: SyncError.invalidBlob) { try await service.processNext() }
            #expect(try store.websiteIcon(for: "https://example.org") == nil)
            #expect(
                try await store.reader.read {
                    try String.fetchOne($0, sql: "SELECT state FROM website_icon_jobs")
                } == "retry")
        }
    }

    @Test func changedConfigurationFencesCompletion() async throws {
        try await withIconPathsAsync { paths in
            let store = try Store(paths: paths)
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org", fetchBody: false))
            try store.setWebsiteIconsEnabled(true)
            let suspended = IconFetchLatch(bytes: try iconPNG())
            let service = WebsiteIconService(store: store, fetch: { _ in await suspended.fetch() })
            let task = Task { try await service.processNext() }
            await suspended.waitUntilStarted()
            let enrollment = try SyncEnrollment(
                endpoint: URL(string: "https://sync.example.org/v1/sync")!,
                binding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()), deviceID: UUID())
            try MacSyncConfiguration(enrollment: enrollment).install(paths: paths)
            await suspended.release()
            await #expect(throws: MacSyncError.configurationChanged) { try await task.value }
            #expect(try store.websiteIcon(for: "https://example.org") == nil)
            #expect(
                !FileManager.default.fileExists(
                    atPath: paths.assetsDirectory.appendingPathComponent("website-icons").path))
        }
    }

    @Test func leaseContentionLeavesRecoverableClaim() async throws {
        try await withIconPathsAsync { paths in
            let store = try Store(paths: paths)
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org", fetchBody: false))
            try store.setWebsiteIconsEnabled(true)
            let bytes = try iconPNG()
            let lease = try #require(try MacSyncLease.acquire(paths: paths))
            defer { withExtendedLifetime(lease) {} }
            await #expect(throws: MacSyncError.busy) {
                try await WebsiteIconService(store: store, fetch: { _ in .normalizedPNG(bytes) })
                    .processNext()
            }
            #expect(try store.websiteIcon(for: "https://example.org") == nil)
            #expect(
                try store.reclaimStaleWebsiteIconClaims(now: Date().addingTimeInterval(61)) == 1)
        }
    }

    @Test func boundedReadRejectsSymlinkAndWrongSize() async throws {
        try await withIconPathsAsync { paths in
            let store = try Store(paths: paths)
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org", fetchBody: false))
            try store.setWebsiteIconsEnabled(true)
            let bytes = try iconPNG()
            #expect(
                try await WebsiteIconService(store: store, fetch: { _ in .normalizedPNG(bytes) })
                    .processNext())
            let record = try #require(try store.websiteIcon(for: "https://example.org"))
            let content = try #require(record.content)
            let path = paths.assetsDirectory.appendingPathComponent("website-icons")
                .appendingPathComponent(content.blob.digest)
            let target = paths.root.appendingPathComponent("synthetic-target.png")
            try bytes.write(to: target)
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
            #expect(throws: SyncError.invalidBlob) { try store.verifiedWebsiteIconData(record) }
            try FileManager.default.removeItem(at: path)
            try Data(count: 262_145).write(to: path)
            #expect(throws: SyncError.invalidBlob) { try store.verifiedWebsiteIconData(record) }
        }
    }

    @Test func syncIngressPreservesClaimsAndTombstonesRestoreDemand() throws {
        try withIconPaths { paths in
            let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let server = try SyncServer(
                databaseURL: paths.root.appendingPathComponent("synthetic-authority.sqlite"),
                blobDirectory: paths.root.appendingPathComponent("synthetic-authority-blobs"),
                libraryID: binding.libraryID, serviceID: binding.serviceID)
            let remote = UUID()
            let record = SharedCapture(
                source: CaptureSource(
                    kind: .link, contentHash: "icon-remote",
                    url: "https://example.org/mobile-origin", host: "forged-other.org"))
            _ = try server.apply(
                SyncOperation(
                    deviceID: remote, sequence: 1, captureID: record.id, baseRevision: 0,
                    mutation: .create(record)))
            let wire = IconCaptureWire(server: server, binding: binding, deviceID: client.deviceID)
            try client.pull(from: wire)
            try store.setWebsiteIconsEnabled(true)
            let claim = try #require(try store.claimNextWebsiteIcon())
            #expect(claim.origin.host == "example.org")
            _ = try server.apply(
                SyncOperation(
                    deviceID: remote, sequence: 2, captureID: record.id, baseRevision: 1,
                    mutation: .edit(CaptureEdit(note: NoteEdit("Unrelated new note")))))
            try client.pull(from: wire)
            #expect(try store.websiteIconClaimIsCurrent(claim))
            #expect(try store.claimNextWebsiteIcon() == nil)
            _ = try server.apply(
                SyncOperation(
                    deviceID: remote, sequence: 3, captureID: record.id, baseRevision: 2,
                    mutation: .delete))
            try client.pull(from: wire)
            #expect(try !store.websiteIconClaimIsCurrent(claim))
            #expect(try store.claimNextWebsiteIcon() == nil)
            _ = try server.apply(
                SyncOperation(
                    deviceID: remote, sequence: 4, captureID: record.id, baseRevision: 3,
                    mutation: .restore))
            try client.pull(from: wire)
            let restored = try #require(try store.claimNextWebsiteIcon())
            #expect(restored.origin == claim.origin)
            #expect(restored.token != claim.token)
        }
    }

    @Test func boundOfflineCompletionUsesIndependentOutboxAndSharedBlobStore() async throws {
        try await withIconPathsAsync { paths in
            let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
            let device = UUID()
            let store = try Store(paths: paths, syncBinding: binding, deviceID: device)
            let client = try #require(store.syncClient)
            let enrollment = try SyncEnrollment(
                endpoint: URL(string: "https://sync.example.org/v1/sync")!, binding: binding,
                deviceID: device)
            try MacSyncConfiguration(enrollment: enrollment).install(paths: paths)
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org/mac-offline", fetchBody: false))
            try store.setWebsiteIconsEnabled(true)
            let captureOperations = try client.pendingOperations()
            let bytes = try iconPNG()
            #expect(
                try await WebsiteIconService(store: store, fetch: { _ in .normalizedPNG(bytes) })
                    .processNext())
            #expect(try client.pendingOperations() == captureOperations)
            let operations = try client.pendingWebsiteIconOperations()
            #expect(operations.count == 1)
            #expect(operations.first?.origin == WebsiteIconOrigin(url: "https://example.org"))
            let record = try #require(try store.websiteIcon(for: "https://example.org/mac-offline"))
            #expect(try client.blobs.read(try #require(record.content?.blob)) == bytes)
            #expect(try store.verifiedWebsiteIconData(record) == bytes)
            #expect(
                !FileManager.default.fileExists(
                    atPath: paths.assetsDirectory.appendingPathComponent("website-icons").path))
        }
    }

    @Test func migrationBackfillsExistingCaptureOrigins() throws {
        try withIconPaths { paths in
            try FileManager.default.createDirectory(
                at: paths.root, withIntermediateDirectories: true)
            let pool = try DatabasePool(path: paths.databaseURL.path)
            try Migrations.migrator.migrate(pool, upTo: "006")
            try pool.write { db in
                for index in 0..<205 {
                    var capture = Capture(
                        kind: .link, url: "https://example.org/item\(index)",
                        body: String(repeating: "synthetic body ", count: 1000),
                        createdAt: Date(timeIntervalSince1970: 1000))
                    try capture.insert(db)
                }
            }
            let store = try Store(paths: paths)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM capture_icon_origins")
                } == 205)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM website_icon_jobs")
                } == 1)
            #expect(try !store.websiteIconsEnabled())
            #expect(try store.claimNextWebsiteIcon() == nil)
        }
    }

    @Test func iconPublicationFailureRollsBackQueueAndSequence() async throws {
        try await withIconPathsAsync { paths in
            let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
            let device = UUID()
            let store = try Store(paths: paths, syncBinding: binding, deviceID: device)
            let client = try #require(store.syncClient)
            let enrollment = try SyncEnrollment(
                endpoint: URL(string: "https://sync.example.org/v1/sync")!, binding: binding,
                deviceID: device)
            try MacSyncConfiguration(enrollment: enrollment).install(paths: paths)
            _ = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.org/mac-offline", fetchBody: false))
            try store.setWebsiteIconsEnabled(true)
            try await store.dbPool.write { db in
                try WebsiteIconDatabase.prepare(db)
                try db.execute(
                    sql:
                        "CREATE TRIGGER synthetic_icon_publication_failure BEFORE INSERT ON sync_website_icon_outbox BEGIN SELECT RAISE(ABORT,'synthetic icon publication failure'); END"
                )
            }
            let bytes = try iconPNG()
            await #expect(throws: (any Error).self) {
                try await WebsiteIconService(store: store, fetch: { _ in .normalizedPNG(bytes) })
                    .processNext()
            }
            #expect(try client.pendingWebsiteIconOperations().isEmpty)
            #expect(try store.websiteIcon(for: "https://example.org") == nil)
            #expect(
                try await store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT sequence FROM sync_website_icon_meta")
                } == 0)
            #expect(
                try store.reclaimStaleWebsiteIconClaims(now: Date().addingTimeInterval(61)) == 1)
        }
    }
}

private struct IconCaptureWire: BoundSyncTransport {
    let server: SyncServer
    let binding: SyncLibraryBinding
    let deviceID: UUID
    func apply(_ operation: SyncOperation) throws -> SyncReceipt { try server.apply(operation) }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try server.changes(after: cursor, limit: limit)
    }
    func baseline() throws -> Baseline { try server.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try server.download(blob) }
}

private func withIconPaths(_ body: (StoragePaths) throws -> Void) throws {
    let paths = StoragePaths(
        root: FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-icon-store-test-\(UUID())"))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try body(paths)
}

private func withIconPathsAsync(_ body: (StoragePaths) async throws -> Void) async throws {
    let paths = StoragePaths(
        root: FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-icon-store-test-\(UUID())"))
    defer { try? FileManager.default.removeItem(at: paths.root) }
    try await body(paths)
}

private actor IconFetchLatch {
    let bytes: Data
    var started = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var fetchWaiter: CheckedContinuation<Void, Never>?
    init(bytes: Data) { self.bytes = bytes }
    func fetch() async -> WebsiteIconFetchOutcome {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { fetchWaiter = $0 }
        return .normalizedPNG(bytes)
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() {
        fetchWaiter?.resume()
        fetchWaiter = nil
    }
}

private func iconPNG() throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let encoded = data as Data
    var stripped = Data(encoded.prefix(8))
    var offset = 8
    while offset + 12 <= encoded.count {
        let size = encoded[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
        let end = offset + 12 + size
        let type = String(decoding: encoded[(offset + 4)..<(offset + 8)], as: UTF8.self)
        guard end <= encoded.count else { throw CocoaError(.fileReadCorruptFile) }
        if ["IHDR", "IDAT", "IEND"].contains(type) { stripped.append(encoded[offset..<end]) }
        offset = end
    }
    return stripped
}
