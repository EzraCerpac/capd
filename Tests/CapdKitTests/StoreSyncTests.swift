import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdKit

@Suite("Opt-in Mac Store sync")
struct StoreSyncTests {
    @Test("Ordinary capture, annotation, rating, reminder and recapture paths reach the authority")
    func userMutations() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let service = CaptureService(store: store)
            let now = Date(timeIntervalSince1970: 1_700_000_000.123456789)
            let first = try service.ingest(
                CaptureRequest(
                    text: "Synthetic kestrel", note: "Initial",
                    sourceAppBundleID: "example.synthetic", capturedAt: now)
            ).capture
            _ = try store.updateNote(
                id: first.id!, note: "Annotation pangolin", now: now.addingTimeInterval(1))
            _ = try store.updateRating(id: first.id!, rating: 5, now: now.addingTimeInterval(2))
            _ = try store.scheduleReminder(
                id: first.id!, at: now.addingTimeInterval(4), now: now.addingTimeInterval(3))
            #expect(try store.claimNextDueReminder(now: now.addingTimeInterval(5))?.id == first.id)
            let reminderTimestamp = try store.syncClient!.pendingOperations().compactMap {
                operation -> Date? in
                guard case .edit(let edit) = operation.mutation else { return nil }
                return edit.metadata?.updatedAt
            }
            #expect(reminderTimestamp.contains(now.addingTimeInterval(5)))
            let recaptured = try service.ingest(
                CaptureRequest(
                    text: "Synthetic kestrel", title: "Filled title",
                    capturedAt: now.addingTimeInterval(6))
            ).capture
            #expect(recaptured.id == first.id)
            let client = try #require(store.syncClient)
            let pending = try client.pendingOperations()
            #expect(pending.map(\.sequence) == Array(1...Int64(pending.count)))
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            #expect(try client.push(to: transport).allSatisfy { $0.outcome == .accepted })
            try client.pull(from: transport)
            let shared = try #require(try server.baseline().captures.first)
            #expect(shared.seenCount == 2)
            #expect(shared.note == "Annotation pangolin")
            #expect(shared.rating == 5)
            #expect(shared.source.title == "Filled title")
            #expect(shared.createdAt == now)
            #expect(shared.metadata?.sourceAppBundleID == "example.synthetic")
            #expect(shared.metadata?.reminderAt == nil)
            #expect(shared.metadata?.lastSeenAt == now.addingTimeInterval(6))
            #expect(shared.metadata?.updatedAt == now.addingTimeInterval(6))
            #expect(
                try SearchService(store: store).search("pangolin").first?.capture.id == first.id)
            let reopened = try Store(paths: paths, syncBinding: binding)
            #expect(reopened.syncClient?.deviceID == client.deviceID)
            #expect(try reopened.syncClient?.pendingOperations().isEmpty == true)
        }
    }

    @Test("Outbox and projection failures roll back capture, identity, metadata, sequence and FTS")
    func transactionRollback() throws {
        try fixture { paths, binding, _ in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            try store.dbPool.write { db in
                try db.execute(
                    sql:
                        "CREATE TRIGGER abort_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT,'synthetic failure'); END"
                )
            }
            #expect(throws: (any Error).self) {
                try CaptureService(store: store).ingest(
                    CaptureRequest(text: "Rollback kestrel", capturedAt: now))
            }
            try store.reader.read { db throws -> Void in
                #expect(try Capture.fetchCount(db) == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_capture_ids") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT sequence FROM sync_meta") == 0)
            }
            #expect(try client.pendingOperations().isEmpty)
            #expect(try SearchService(store: store).search("kestrel").isEmpty)
            try store.dbPool.write { db in try db.execute(sql: "DROP TRIGGER abort_outbox") }
            let capture = try CaptureService(store: store).ingest(
                CaptureRequest(text: "Rollback kestrel", note: "Original", capturedAt: now)
            ).capture
            let operations = try client.pendingOperations()
            try store.dbPool.write { db in
                try db.execute(
                    sql:
                        "CREATE TRIGGER abort_outbox BEFORE INSERT ON sync_outbox BEGIN SELECT RAISE(ABORT,'synthetic edit failure'); END"
                )
            }
            #expect(throws: (any Error).self) {
                _ = try store.updateNote(id: capture.id!, note: "Never committed")
            }
            #expect(try SearchService(store: store).capture(id: capture.id!) == capture)
            #expect(try client.pendingOperations() == operations)
            #expect(throws: (any Error).self) { try store.deleteCaptures(ids: [capture.id!]) }
            #expect(try SearchService(store: store).capture(id: capture.id!) == capture)
            try store.dbPool.write { db in
                try db.execute(
                    sql:
                        "DROP TRIGGER abort_outbox; CREATE TRIGGER abort_projection BEFORE UPDATE ON captures BEGIN SELECT RAISE(ABORT,'synthetic projection failure'); END"
                )
            }
            #expect(throws: (any Error).self) {
                try CaptureService(store: store).ingest(CaptureRequest(text: "Projection rollback"))
            }
            #expect(try client.pendingOperations() == operations)
            #expect(try SearchService(store: store).search("projection").isEmpty)
        }
    }

    @Test(
        "Offline image delete keeps original identity and queued blob through sweep, retry and reopen"
    )
    func imageDeletion() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let bytes = Data("synthetic nested image".utf8)
            let capture = try CaptureService(store: store).ingest(CaptureRequest(imageData: bytes))
                .capture
            let client = try #require(store.syncClient)
            let create = try #require(try client.pendingOperations().first)
            #expect(try store.deleteCaptures(ids: [capture.id!]).map(\.id) == [capture.id])
            let operations = try client.pendingOperations()
            #expect(operations.count == 2)
            #expect(operations[1].captureID == create.captureID)
            #expect(operations[1].predecessorID == create.id)
            _ = try store.sweepOrphanAssets(unusedFor: 0)
            let blob = try #require(try client.captures(includeDeleted: true).first?.source.blob)
            #expect(try client.blobs.read(blob) == bytes)
            let reopened = try Store(paths: paths, syncBinding: binding)
            let retryClient = try #require(reopened.syncClient)
            #expect(try retryClient.pendingOperations() == operations)
            try retryClient.push(
                to: StoreTestTransport(
                    server: server, binding: binding, deviceID: retryClient.deviceID))
            #expect(try server.baseline().captures.first?.id == create.captureID)
            #expect(try server.baseline().captures.first?.deleted == true)
            #expect(try server.download(blob) == bytes)
            #expect(try SearchService(store: reopened).capture(id: capture.id!) == nil)
            let next = try CaptureService(store: reopened).ingest(
                CaptureRequest(text: "After deletion")
            ).capture
            #expect(next.id! > capture.id!)
            try reopened.reader.read { db throws -> Void in
                #expect(
                    try String.fetchOne(
                        db, sql: "SELECT global_id FROM sync_capture_ids WHERE local_id=?",
                        arguments: [capture.id]) == create.captureID.uuidString)
            }
        }
    }

    @Test(
        "Shared writers use one outbox; stale local handles fail closed; populated enrollment refuses"
    )
    func enrollmentAndWriters() throws {
        try fixture { paths, binding, _ in
            let stale = try Store(paths: paths)
            let first = try Store(paths: paths, syncBinding: binding)
            let second = try Store(paths: paths, syncBinding: binding)
            #expect(first.syncClient?.deviceID == second.syncClient?.deviceID)
            #expect(throws: SyncBindingError.mismatch) {
                try CaptureService(store: stale).ingest(CaptureRequest(text: "Stale writer"))
            }
            _ = try CaptureService(store: first).ingest(CaptureRequest(text: "App capture"))
            _ = try CaptureService(store: second).ingest(CaptureRequest(text: "CLI capture"))
            #expect(try first.syncClient?.pendingOperations().map(\.sequence) == [1, 2])
            let localPaths = StoragePaths(root: paths.root.appendingPathComponent("local-library"))
            let local = try Store(paths: localPaths)
            _ = try CaptureService(store: local).ingest(
                CaptureRequest(text: "Existing local capture"))
            #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
                try Store(paths: localPaths, syncBinding: binding)
            }
            #expect(try SearchService(store: local).totalCaptureCount() == 1)
            #expect(try local.reader.read { db in try db.tableExists("sync_binding") } == false)
        }
    }

    @Test(
        "Enrichment and bulk taxonomy changes retain separate manual tags and enqueue visible content"
    )
    func enrichmentAndTags() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let now = Date(timeIntervalSince1970: 1_700_000_000.123456789)
            let link = try CaptureService(store: store).ingest(
                CaptureRequest(url: "https://example.invalid/synthetic", capturedAt: now)
            ).capture
            let count = try client.pendingOperations().count
            _ = try store.claimForEnrichment(id: link.id!, now: now.addingTimeInterval(1))
            #expect(try client.pendingOperations().count == count)
            _ = try store.completeEnrichment(
                id: link.id!,
                result: StepResult(
                    ocrText: "Axolotl OCR",
                    bodyExtraction: BodyExtractionResult(
                        body: "Pangolin body", status: .ok, source: .fetch, title: "Filled title")),
                state: .ok, now: now.addingTimeInterval(2))
            let taxonomy = Taxonomy(version: 2, tags: ["generated"], updatedAt: now)
            try store.completeTagging(
                id: link.id!, tags: ["generated"], taxonomy: taxonomy,
                now: now.addingTimeInterval(3))
            let second = try CaptureService(store: store).ingest(
                CaptureRequest(text: "Second synthetic", capturedAt: now)
            ).capture
            try store.completeTagging(
                id: second.id!, tags: ["generated"], taxonomy: taxonomy,
                now: now.addingTimeInterval(3))
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            try client.push(to: transport)
            let linkID = try store.dbPool.write { db in try StoreSync.identity(db, capture: link) }
            let peer = try SyncClient(
                databaseURL: paths.root.appendingPathComponent("peer.sqlite"),
                blobDirectory: paths.root.appendingPathComponent("peer-assets"), binding: binding)
            let peerTransport = StoreTestTransport(
                server: server, binding: binding, deviceID: peer.deviceID)
            try peer.pull(from: peerTransport)
            try peer.enqueue(captureID: linkID, mutation: .edit(CaptureEdit(addTags: ["manual"])))
            try peer.push(to: peerTransport)
            try client.pull(from: transport)
            try store.applyTaxonomyRevision(
                mapping: ["generated": "renamed"],
                taxonomy: Taxonomy(version: 3, tags: ["renamed"], updatedAt: now), batchSize: 1,
                now: now.addingTimeInterval(4))
            try client.push(to: transport)
            let mixed = try #require(try server.baseline().captures.first { $0.id == linkID })
            #expect(mixed.manualTags == ["manual"])
            #expect(mixed.generated.tags == ["renamed"])
            #expect(mixed.metadata?.updatedAt == now.addingTimeInterval(4))
            #expect(mixed.generated.body == "Pangolin body")
            #expect(mixed.generated.ocrText == "Axolotl OCR")
            #expect(mixed.source.title == "Filled title")
            try store.requestRetagging(now: now.addingTimeInterval(5))
            #expect(try store.prepareRetagging(tags: ["new"], now: now.addingTimeInterval(6)) == 2)
            try client.push(to: transport)
            let baseline = try server.baseline()
            #expect(baseline.captures.allSatisfy { $0.generated.tags.isEmpty })
            #expect(baseline.captures.first { $0.id == linkID }?.manualTags == ["manual"])
            #expect(
                baseline.captures.allSatisfy { $0.metadata?.updatedAt == now.addingTimeInterval(6) }
            )
            #expect(try SearchService(store: store).search("manual").first?.capture.id == link.id)
        }
    }

    @Test("Authority aliases reuse the local integer key without duplicating FTS or pending bytes")
    func canonicalAliasProjection() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let local = try CaptureService(store: store).ingest(
                CaptureRequest(
                    text: "Alias kestrel", capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
            ).capture
            let client = try #require(store.syncClient)
            let original = try #require(try client.pendingOperations().first)
            let raw = try store.reader.read { db in
                try Data.fetchAll(db, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
            }
            let peer = try SyncClient(
                databaseURL: paths.root.appendingPathComponent("peer.sqlite"),
                blobDirectory: paths.root.appendingPathComponent("peer-assets"), binding: binding)
            let canonical = SharedCapture(
                source: CaptureSource(
                    kind: .text, contentHash: local.contentHash, selection: "Alias kestrel"),
                createdAt: local.createdAt)
            try peer.enqueue(captureID: canonical.id, mutation: .create(canonical))
            try peer.push(
                to: StoreTestTransport(server: server, binding: binding, deviceID: peer.deviceID))
            // Capture and create payload remain untouched until the authority issues an alias receipt.
            #expect(
                try store.reader.read {
                    try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
                } == raw)
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            let receipt = try #require(try client.push(to: transport).first)
            #expect(receipt.capture?.id == canonical.id)
            #expect(original.captureID != canonical.id)
            try client.pull(from: transport)
            let projected = try #require(try SearchService(store: store).capture(id: local.id!))
            #expect(projected.seenCount == 2)
            #expect(try store.reader.read { try Capture.fetchCount($0) } == 1)
            #expect(try SearchService(store: store).search("kestrel").count == 1)
            #expect(
                try store.reader.read {
                    try String.fetchOne(
                        $0, sql: "SELECT global_id FROM sync_capture_ids WHERE local_id=?",
                        arguments: [local.id])
                } == canonical.id.uuidString)
            _ = try store.updateRating(id: local.id!, rating: 5)
            #expect(try client.pendingOperations().first?.captureID == canonical.id)
        }
    }

    @Test("A rejected recapture alias to a tombstone removes every local projection")
    func tombstoneAliasProjection() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            let service = CaptureService(store: store)
            let first = try service.ingest(CaptureRequest(text: "Tombstone kestrel")).capture
            let originalID = try #require(try client.pendingOperations().first?.captureID)
            try client.push(to: transport)
            _ = try store.deleteCaptures(ids: [first.id!])
            try client.push(to: transport)
            let later = try service.ingest(CaptureRequest(text: "Tombstone kestrel")).capture
            #expect(later.id! > first.id!)
            let pending = try #require(try client.pendingOperations().first)
            #expect(pending.captureID != originalID)
            #expect(try SearchService(store: store).search("kestrel").isEmpty)
            let receipt = try #require(try client.push(to: transport).first)
            #expect(receipt.outcome == .deleted)
            #expect(receipt.capture?.id == originalID)
            #expect(try SearchService(store: store).capture(id: later.id!) == nil)
            try client.pull(from: transport)
            #expect(try SearchService(store: store).capture(id: later.id!) == nil)
            #expect(try SearchService(store: store).search("kestrel").isEmpty)
            #expect(try store.reader.read { try Capture.fetchCount($0) } == 0)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_capture_ids")
                } == 2)
            #expect(try client.pendingOperations().isEmpty)
            #expect(try client.rejectedWork().first?.operation == pending)
            let reopened = try Store(paths: paths, syncBinding: binding)
            #expect(try SearchService(store: reopened).search("kestrel").isEmpty)
        }
    }

    @Test("Pulled generated tags stay processed and sync blobs enforce library ownership")
    func generatedProjectionAndBlobOwnership() throws {
        try fixture { paths, binding, server in
            let peer = try SyncClient(
                databaseURL: paths.root.appendingPathComponent("peer.sqlite"),
                blobDirectory: paths.root.appendingPathComponent("peer-assets"), binding: binding)
            var shared = SharedCapture(
                id: UUID(), source: CaptureSource(kind: .text, contentHash: "remote-tags"),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            shared.generated.tags = ["remote-generated"]
            try peer.enqueue(captureID: shared.id, mutation: .create(shared))
            try peer.push(
                to: StoreTestTransport(
                    server: server, binding: binding, deviceID: peer.deviceID))
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            try client.pull(
                from: StoreTestTransport(
                    server: server, binding: binding, deviceID: client.deviceID))
            let local = try #require(try store.reader.read { try Capture.fetchAll($0).first })
            #expect(local.tagsVersion > 0)
            #expect(local.tagList == ["remote-generated"])
            #expect(try store.untaggedCaptures(limit: 10).isEmpty)
            #expect(try client.pendingOperations().isEmpty)
            let marker = client.blobs.directory.appendingPathComponent("library-owner")
            #expect(
                try JSONDecoder().decode(SyncLibraryBinding.self, from: Data(contentsOf: marker))
                    == binding)
            #expect(throws: SyncBindingError.mismatch) {
                try BlobStore(
                    directory: client.blobs.directory,
                    binding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()))
            }
        }
    }

    private func fixture(_ body: (StoragePaths, SyncLibraryBinding, SyncServer) throws -> Void)
        throws
    {
        let root = URL(fileURLWithPath: "/private/tmp/capd-store-sync-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-assets"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        try body(StoragePaths(root: root.appendingPathComponent("mac")), binding, server)
    }
}

private struct StoreTestTransport: BoundSyncTransport {
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
