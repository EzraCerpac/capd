import CapdSync
import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing

@testable import CapdKit

@Suite("Opt-in Mac Store sync")
struct StoreSyncTests {
    @Test func captureBatchIsolatesWriteFailuresWithoutReorderingResults() throws {
        try fixture { paths, binding, _ in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            try store.dbPool.write { db in
                try db.execute(
                    sql: """
                        CREATE TRIGGER reject_bad_capture BEFORE INSERT ON sync_outbox
                        WHEN instr(CAST(NEW.payload AS TEXT), 'Rejected synthetic row') > 0
                        BEGIN SELECT RAISE(ABORT,'synthetic per-row refusal'); END
                        """)
            }
            let results = CaptureService(store: store).ingest([
                CaptureRequest(text: "First good row"),
                CaptureRequest(text: "Rejected synthetic row"),
                CaptureRequest(text: "Last good row"), CaptureRequest(),
                CaptureRequest(text: "First good row"),
            ])
            #expect(results.count == 5)
            let first = try results[0].get()
            #expect(throws: (any Error).self) { try results[1].get() }
            let last = try results[2].get()
            #expect(throws: CaptureError.emptyRequest) { try results[3].get() }
            let duplicate = try results[4].get()
            #expect(first.capture.id! < last.capture.id!)
            #expect(duplicate.capture.id == first.capture.id)
            #expect(duplicate.capture.seenCount == 2)
            let operations = try client.pendingOperations()
            #expect(operations.map(\.sequence) == [1, 2, 3, 4])
            #expect(try SearchService(store: store).search("Rejected synthetic").isEmpty)
            #expect(try store.reader.read { try Capture.fetchCount($0) } == 2)
        }
    }

    @Test(arguments: [false, true])
    func captureBatchRepeatsTombstoneSequentialFallback(acceptedDelete: Bool) throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            let service = CaptureService(store: store)
            let first = try service.ingest(CaptureRequest(text: "Repeated tombstone")).capture
            let originalID = try #require(try client.pendingOperations().first?.captureID)
            try client.push(to: transport)
            _ = try store.deleteCaptures(ids: [first.id!])
            if acceptedDelete { try client.push(to: transport) }
            let prior = try client.pendingOperations()
            let results = try service.ingest([
                CaptureRequest(text: "Repeated tombstone"),
                CaptureRequest(text: "Repeated tombstone"),
            ]).map { try $0.get() }
            #expect(results[0].capture.id! > first.id!)
            #expect(results[1].capture.id! > results[0].capture.id!)
            #expect(results.allSatisfy { $0.capture.seenCount == 1 })
            let operations = try client.pendingOperations()
            #expect(Array(operations.prefix(prior.count)) == prior)
            let creates = Array(operations.dropFirst(prior.count))
            #expect(creates.count == 2)
            #expect(creates[0].captureID != originalID)
            #expect(creates[1].captureID != creates[0].captureID)
            for operation in creates {
                guard case .create = operation.mutation else {
                    Issue.record("Expected a new create")
                    return
                }
            }
            #expect(creates.map(\.sequence) == [3, 4])
            #expect(creates.allSatisfy { $0.baseRevision == 0 && $0.predecessorID == nil })
            #expect(try store.reader.read { try Capture.fetchCount($0) } == 0)
            #expect(try SearchService(store: store).search("Repeated tombstone").isEmpty)
            #expect(try client.push(to: transport).suffix(2).allSatisfy { $0.outcome == .deleted })
            #expect(try client.pendingOperations().isEmpty)
            #expect(try server.baseline().captures.first?.id == originalID)
            #expect(try server.baseline().captures.first?.deleted == true)
        }
    }

    @Test func unsyncedBatchKeepsSaturatedCountAndInputOrder() throws {
        try fixture { paths, _, _ in
            let store = try Store(paths: paths)
            let service = CaptureService(store: store)
            let original = try service.ingest(CaptureRequest(text: "Local maximum")).capture
            try store.dbPool.write { db in
                try db.execute(
                    sql: "UPDATE captures SET seen_count=? WHERE id=?",
                    arguments: [Int.max, original.id])
            }
            let results = try service.ingest([
                CaptureRequest(text: "Local maximum"), CaptureRequest(text: "New local row"),
                CaptureRequest(text: "Local maximum"),
            ]).map { try $0.get() }
            #expect(results[0].capture.id == original.id)
            #expect(results[2].capture.id == original.id)
            #expect(results[0].capture.seenCount == Int.max)
            #expect(results[2].capture.seenCount == Int.max)
            #expect(try store.reader.read { try Capture.fetchCount($0) } == 2)
        }
    }

    @Test func batchDuplicateOutcomesMatchSequentialTaggingInvalidation() throws {
        try fixture { paths, binding, _ in
            let store = try Store(paths: paths, syncBinding: binding)
            let control = try Store(
                paths: StoragePaths(root: paths.root.appendingPathComponent("control")),
                syncBinding: binding)
            let initialTime = Date(timeIntervalSince1970: 1_700_000_000)
            for candidate in [store, control] {
                let original = try CaptureService(store: candidate).ingest(
                    CaptureRequest(text: "Tagging source", capturedAt: initialTime)
                ).capture
                #expect(
                    try candidate.completeTagging(
                        id: original.id!, tags: [],
                        taxonomy: Taxonomy(version: 2, tags: [], updatedAt: initialTime),
                        now: initialTime))
            }
            let requests = [
                CaptureRequest(
                    text: "Tagging source", title: "New title", note: "Added note",
                    tags: ["zebra", "apple"], capturedAt: initialTime.addingTimeInterval(1)),
                CaptureRequest(
                    text: "Tagging source", title: "Ignored title", tags: ["ignored"],
                    capturedAt: initialTime.addingTimeInterval(2)),
            ]
            let expected = try requests.map { try CaptureService(store: control).ingest($0) }
            let actual = try CaptureService(store: store).ingest(requests).map { try $0.get() }
            #expect(actual == expected)
            #expect(actual[1].capture.tagsVersion == 0)
            let persisted = try store.reader.read {
                try Capture.fetchAll($0, sql: "SELECT * FROM captures ORDER BY id")
            }
            let reference = try control.reader.read {
                try Capture.fetchAll($0, sql: "SELECT * FROM captures ORDER BY id")
            }
            #expect(persisted == reference)
        }
    }

    @Test func atomicCaptureBatchRollsBackAndPreservesAdmission() throws {
        try fixture { paths, binding, _ in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let sentinel = try CaptureService(store: store).ingest(CaptureRequest(text: "Sentinel"))
            let original = try client.pendingOperations()
            let before = try store.reader.read {
                try Capture.fetchAll($0, sql: "SELECT * FROM captures ORDER BY id")
            }
            let sequence = try store.reader.read {
                try Int64.fetchOne($0, sql: "SELECT sequence FROM sync_meta")
            }
            try store.dbPool.write { db in
                try db.execute(sql: "CREATE TABLE bulk_audit (id TEXT)")
                try db.execute(
                    sql:
                        "CREATE TRIGGER audit_bulk AFTER UPDATE ON sync_visible BEGIN INSERT INTO bulk_audit VALUES (NEW.id); END"
                )
                try db.execute(
                    sql:
                        "CREATE TRIGGER fail_bulk BEFORE INSERT ON sync_outbox WHEN NEW.sequence=3 BEGIN SELECT RAISE(ABORT,'synthetic failed batch'); END"
                )
            }
            let captures = (1...3).map {
                Capture(
                    kind: .text, selection: "Batch source \($0)", contentHash: "batch-source-\($0)",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            }
            #expect(throws: (any Error).self) { try store.upsertCaptures(captures) }
            #expect(try client.pendingOperations() == original)
            let after = try store.reader.read {
                try Capture.fetchAll($0, sql: "SELECT * FROM captures ORDER BY id")
            }
            #expect(after == before)
            #expect(
                try store.reader.read {
                    try Int64.fetchOne($0, sql: "SELECT sequence FROM sync_meta")
                } == sequence)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bulk_audit")
                } == 0)
            #expect(try SearchService(store: store).search("Batch source").isEmpty)
            #expect(try SearchService(store: store).capture(id: sentinel.capture.id!) != nil)
            try store.dbPool.write { try $0.execute(sql: "DROP TRIGGER fail_bulk") }
            var invalid = captures[1]
            invalid.rating = 0
            #expect(throws: (any Error).self) {
                try store.upsertCaptures([captures[0], invalid, captures[2]])
            }
            #expect(try client.pendingOperations() == original)
            #expect(try store.reader.read { try Capture.fetchCount($0) } == 1)
            #expect(throws: SyncError.invalidOperation) {
                try store.upsertCaptures(
                    Array(repeating: captures[0], count: Store.captureBatchSize + 1))
            }
            _ = try store.upsertCaptures(captures)
            #expect(try client.pendingOperations().map(\.sequence) == Array(1...4))
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bulk_audit")
                } == 1)
        }
    }

    @Test func pinboardBulkCapturesProjectOnceAndKeepDuplicateOrder() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let service = CaptureService(store: store)
            _ = try service.ingest(CaptureRequest(text: "Existing sentinel"))
            let client = try #require(store.syncClient)
            try store.dbPool.write { db in
                try db.execute(sql: "CREATE TABLE ingest_projections (id TEXT)")
                for event in ["INSERT", "UPDATE"] {
                    try db.execute(
                        sql:
                            "CREATE TRIGGER ingest_\(event) AFTER \(event) ON sync_visible BEGIN INSERT INTO ingest_projections VALUES (NEW.id); END"
                    )
                }
            }
            let data = Data(
                """
                [{"href":"https://example.com/a","description":"First title","tags":"manual","time":"2020-01-01T00:00:00Z"},
                 {"href":"https://example.com/b","time":"2020-01-02T00:00:00Z"},
                 {"href":"https://example.com/a","extended":"Later note","tags":"ignored","time":"2020-01-03T00:00:00Z"},
                 {"href":"https://example.com/c","time":"2020-01-04T00:00:00Z"}]
                """.utf8)
            let summary = try PinboardImporter(captures: service).run(data: data)
            #expect(summary.imported == 3 && summary.merged == 1 && summary.failures.isEmpty)
            let projected = try store.reader.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM ingest_projections")
            }
            #expect(projected == 4)
            let queued = try client.pendingOperations()
            #expect(queued.map(\.sequence) == Array(1...6))
            #expect(queued[3].captureID == queued[1].captureID)
            #expect(queued[3].predecessorID == queued[1].id)
            #expect(queued[4].predecessorID == queued[3].id)
            let duplicate = try #require(
                try store.reader.read {
                    try Capture.filter(Capture.CodingKeys.url == "https://example.com/a").fetchOne(
                        $0)
                })
            #expect(duplicate.seenCount == 2 && duplicate.note == "Later note")
            #expect(duplicate.title == "First title" && duplicate.tagList == ["manual"])
            let id = try #require(duplicate.id)
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            try client.push(to: transport)
            try client.pull(from: transport)
            #expect(try client.pendingOperations().isEmpty)
            #expect(try SearchService(store: store).capture(id: id)?.seenCount == 2)
            #expect(try SearchService(store: store).capture(id: id)?.note == "Later note")
        }
    }

    @Test func recaptureSaturatesProtocolMaximumSeenCount() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let url = URL(string: "https://example.com/max-count")!
            var record = SharedCapture(
                source: CaptureSource(
                    kind: .link, contentHash: CaptureIdentity.contentHash(for: url),
                    url: url.absoluteString),
                createdAt: Date(timeIntervalSince1970: 1_600_000_000))
            record.seenCount = Int.max
            let snapshot = ContentSnapshotImport(
                snapshotID: UUID(), targetBinding: binding, sourceDeviceID: UUID(),
                captures: [record])
            _ = try server.importContentSnapshot(
                snapshot, preview: server.previewContentSnapshotImport(snapshot))
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            try client.pull(from: transport)
            let saved = try CaptureService(store: store).ingest(
                CaptureRequest(
                    url: url.absoluteString,
                    fetchBody: false, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
            ).capture
            #expect(saved.seenCount == Int.max)
            try client.push(to: transport)
            try client.pull(from: transport)
            #expect(try server.baseline().captures.first?.seenCount == Int.max)
            let reopened = try Store(paths: paths, syncBinding: binding, deviceID: client.deviceID)
            #expect(try SearchService(store: reopened).capture(id: saved.id!)?.seenCount == Int.max)
        }
    }

    @Test(arguments: ["root", "ancestor"])
    func imageCaptureUnderSymlinkedLibrary(kind: String) throws {
        try fixture { originalPaths, binding, server in
            let paths = try symlinkedPaths(originalPaths, kind: kind)
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let bytes = Data("synthetic symlink-root image".utf8)
            let capture = try CaptureService(store: store).ingest(
                CaptureRequest(
                    imageData: bytes, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
            ).capture
            let path = try #require(capture.assetPath)
            #expect(try Data(contentsOf: paths.assetURL(forRelativePath: path)) == bytes)
            let queued = try client.pendingOperations()
            #expect(queued.map(\.sequence) == [1])
            guard case .create(let record) = try #require(queued.first).mutation else {
                Issue.record("Image capture did not queue a create")
                return
            }
            let blob = try #require(record.source.blob)
            #expect(blob == BlobReference(data: bytes))
            try client.push(
                to: StoreTestTransport(
                    server: server, binding: binding, deviceID: client.deviceID))
            #expect(try client.pendingOperations().isEmpty)
            #expect(try server.download(blob) == bytes)
            #expect(try server.baseline().captures.first?.source.blob == blob)
            #expect(try SearchService(store: store).capture(id: capture.id!)?.assetPath == path)
        }
    }

    @Test(arguments: ["root", "ancestor"])
    func importedImageUnderSymlinkedLibrary(kind: String) throws {
        try fixture { originalPaths, binding, server in
            let paths = try symlinkedPaths(originalPaths, kind: kind)
            let local = try Store(paths: paths)
            let bytes = Data("synthetic imported symlink-root image".utf8)
            let capture = try CaptureService(store: local).ingest(
                CaptureRequest(
                    imageData: bytes, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
            ).capture
            let id = try local.dbPool.write { db in
                try StoreSync.prepareIDs(db)
                return try StoreSync.identity(db, capture: capture)
            }
            let blob = try #require(try StoreSync.reference(for: capture, paths: paths))
            #expect(blob == BlobReference(data: bytes))
            try server.upload(blob, offset: 0, chunk: bytes, final: true)
            let deviceID = UUID()
            let snapshot = ContentSnapshotImport(
                snapshotID: UUID(), targetBinding: binding, sourceDeviceID: deviceID,
                captures: [StoreSync.snapshot(capture, id: id, blob: blob)])
            _ = try server.importContentSnapshot(
                snapshot, preview: server.previewContentSnapshotImport(snapshot))
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: deviceID)
            let handoff = try StoreSyncImportHandoff(store: local, transport: transport)
            let store = try Store(paths: paths, syncBinding: binding, imported: handoff)
            let client = try #require(store.syncClient)
            #expect(try client.pendingOperations().isEmpty)
            #expect(try client.blobs.read(blob) == bytes)
            #expect(
                try SearchService(store: store).capture(id: capture.id!)?.assetPath
                    == capture.assetPath)
            _ = try store.updateNote(id: capture.id!, note: "Imported image note")
            #expect(try client.pendingOperations().map(\.sequence) == [1])
            try client.push(to: transport)
            #expect(try client.pendingOperations().isEmpty)
            #expect(try server.download(blob) == bytes)
        }
    }

    @Test(arguments: [
        "file-inside", "file-escape", "directory-inside", "directory-escape", "absolute",
        "traversal",
    ])
    func unsafeAssetPathsCannotQueueCapture(kind: String) throws {
        try fixture { paths, binding, _ in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let bytes = Data("synthetic rejected asset".utf8)
            let target = (kind.hasSuffix("inside") ? paths.assetsDirectory : paths.root)
                .appendingPathComponent("target/image.png")
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
            let path: String
            if kind.hasPrefix("file") {
                path = "linked.png"
                try FileManager.default.createSymbolicLink(
                    at: paths.assetURL(forRelativePath: path), withDestinationURL: target)
            } else if kind.hasPrefix("directory") {
                path = "linked/image.png"
                try FileManager.default.createSymbolicLink(
                    at: paths.assetsDirectory.appendingPathComponent("linked"),
                    withDestinationURL: target.deletingLastPathComponent())
            } else {
                path = kind == "absolute" ? target.path : "../target/image.png"
            }
            let blobFiles = try FileManager.default.contentsOfDirectory(
                atPath: client.blobs.directory.path
            ).sorted()
            #expect(throws: SyncError.invalidBlob) {
                try store.upsertCapture(
                    Capture(kind: .image, assetPath: path, contentHash: "unsafe", createdAt: Date())
                )
            }
            #expect(try SearchService(store: store).totalCaptureCount() == 0)
            #expect(try client.pendingOperations().isEmpty)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_capture_ids")
                } == 0)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: client.blobs.directory.path)
                    .sorted() == blobFiles)
            #expect(try Data(contentsOf: target) == bytes)
            _ = try CaptureService(store: store).ingest(CaptureRequest(imageData: bytes))
            #expect(try client.pendingOperations().map(\.sequence) == [1])
        }
    }

    private func symlinkedPaths(_ paths: StoragePaths, kind: String) throws -> StoragePaths {
        let real = paths.root.deletingLastPathComponent().appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.root, withDestinationURL: real)
        return kind == "root"
            ? paths : StoragePaths(root: paths.root.appendingPathComponent("library"))
    }

    @Test func largeNoteChainCrossesAcknowledgedPredecessor() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let quarter = SyncHTTPHandler.maximumBodyBytes / 4
            let record = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "mixed-note-chain"), note: "a")
            _ = try server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: record.id, baseRevision: 0,
                    mutation: .create(record)))
            let principal = SyncPrincipal(
                serviceID: binding.serviceID, libraryID: binding.libraryID,
                deviceID: client.deviceID)
            let handler = SyncHTTPHandler(
                serviceID: binding.serviceID,
                authorizer: StoreBudgetAuthorizer(principal: principal), server: { _ in server })
            let wire = SyncHTTPTransport(
                binding: binding, deviceID: client.deviceID, credential: { "synthetic-budget" },
                execute: { handler.handle($0) })
            try client.pull(from: wire)
            let final = String(repeating: "c", count: quarter * 3)
            let operations = try store.dbPool.write {
                try client.enqueue(
                    in: $0,
                    edits: [
                        (
                            record.id,
                            CaptureEdit(note: NoteEdit(String(repeating: "b", count: quarter)))
                        ),
                        (record.id, CaptureEdit(rating: 3)),
                        (record.id, CaptureEdit(note: NoteEdit(final))),
                    ])
            }
            #expect(throws: SyncError.transportDisconnected) {
                try client.push(to: StorePartialPushTransport(base: wire))
            }
            let remaining = try client.pendingOperations()
            #expect(remaining.map(\.id) == operations.dropFirst().map(\.id))
            try client.enqueue(captureID: record.id, mutation: .edit(CaptureEdit(rating: 4)))
            try client.push(to: wire)
            #expect(try client.pendingOperations().count == 0)
            let accepted = try #require(wire.baseline().captures.first)
            #expect(
                SHA256.hash(data: Data(accepted.note!.utf8)).description
                    == SHA256.hash(data: Data(final.utf8)).description)
            #expect(accepted.noteConflicts.isEmpty)
            #expect(accepted.rating == 4)
        }
    }

    @Test func largeSequentialNotesRemainSendable() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let size = SyncHTTPHandler.maximumBodyBytes / 2
            let record = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "large-note-chain"),
                note: String(repeating: "a", count: size))
            _ = try server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: record.id, baseRevision: 0,
                    mutation: .create(record)))
            let principal = SyncPrincipal(
                serviceID: binding.serviceID, libraryID: binding.libraryID,
                deviceID: client.deviceID)
            let handler = SyncHTTPHandler(
                serviceID: binding.serviceID,
                authorizer: StoreBudgetAuthorizer(principal: principal), server: { _ in server })
            let wire = SyncHTTPTransport(
                binding: binding, deviceID: client.deviceID, credential: { "synthetic-budget" },
                execute: { handler.handle($0) })
            try client.pull(from: wire)
            let final = String(repeating: "c", count: size)
            let operations = try store.dbPool.write {
                try client.enqueue(
                    in: $0,
                    edits: [
                        (
                            record.id,
                            CaptureEdit(note: NoteEdit(String(repeating: "b", count: size)))
                        ), (record.id, CaptureEdit(note: NoteEdit(final))),
                    ])
            }
            #expect(operations.map(\.sequence) == [1, 2])
            #expect(operations[1].predecessorID == operations[0].id)
            try client.push(to: wire)
            #expect(try client.pendingOperations().count == 0)
            let accepted = try #require(wire.baseline().captures.first)
            let digest = SHA256.hash(data: Data(accepted.note!.utf8)).description
            #expect(digest == SHA256.hash(data: Data(final.utf8)).description)
            #expect(accepted.noteConflicts.isEmpty)
        }
    }

    @Test func acceptedDeviceKnowledgeRollsBackAndSurvivesRecoveryAndReopen() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let peer = UUID()
            let first = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "observed-first"))
            _ = try server.apply(
                SyncOperation(
                    deviceID: peer, sequence: 1, captureID: first.id, baseRevision: 0,
                    mutation: .create(first)))
            for sequence in 2...9 {
                _ = try server.apply(
                    SyncOperation(
                        deviceID: peer, sequence: Int64(sequence), captureID: UUID(),
                        baseRevision: 0, mutation: .edit(CaptureEdit(rating: 3))))
            }
            try server.expireFeed(through: 1)
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            try client.pull(from: transport)
            func known(_ store: Store) throws -> [UUID: Int64] {
                try store.reader.read { db in
                    Dictionary(
                        uniqueKeysWithValues: try Row.fetchAll(
                            db, sql: "SELECT id, sequence FROM sync_devices"
                        ).map { (UUID(uuidString: $0["id"] as String)!, $0["sequence"] as Int64) })
                }
            }
            #expect(try known(store) == [peer: 9])
            let secondPeer = UUID()
            let second = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "observed-second"))
            _ = try server.apply(
                SyncOperation(
                    deviceID: secondPeer, sequence: 1, captureID: second.id, baseRevision: 0,
                    mutation: .create(second)))
            try store.dbPool.write {
                try $0.execute(
                    sql:
                        "CREATE TRIGGER abort_observed_projection BEFORE INSERT ON captures WHEN NEW.content_hash='observed-second' BEGIN SELECT RAISE(ABORT,'synthetic projection failure'); END"
                )
            }
            #expect(throws: (any Error).self) { try client.pull(from: transport) }
            #expect(try known(store) == [peer: 9])
            #expect(try client.cursor() == 1)
            #expect(try client.captures().count == 1)
            try store.dbPool.write { try $0.execute(sql: "DROP TRIGGER abort_observed_projection") }
            try client.pull(from: transport)
            let baseline = try server.baseline()
            #expect(try known(store) == [peer: 9, secondPeer: 1])
            let ahead = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "observed-ahead"))
            try client.enqueue(captureID: ahead.id, mutation: .create(ahead))
            try client.push(to: transport)
            #expect(try known(store) == [peer: 9, secondPeer: 1, client.deviceID: 1])
            let recovery = StoreSnapshotTransport(base: transport, snapshot: baseline)
            try client.pull(from: recovery)
            #expect(try client.captures().count == 3)
            #expect(try known(store) == [peer: 9, secondPeer: 1, client.deviceID: 1])
            let reopened = try Store(paths: paths, syncBinding: binding, deviceID: client.deviceID)
            #expect(try known(reopened) == known(store))
            let malformed = Baseline(
                cursor: baseline.cursor, captures: baseline.captures,
                deviceSequences: [peer: 1, secondPeer: -1])
            #expect(throws: (any Error).self) {
                try client.pull(from: StoreSnapshotTransport(base: transport, snapshot: malformed))
            }
            #expect(try known(store) == [peer: 9, secondPeer: 1, client.deviceID: 1])
            #expect(try client.captures().count == 3)
        }
    }

    @Test(arguments: ["intermediate", "conflict", "duplicate"])
    func knownAuthorityReplyGrowthIsRejected(kind: String) throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let quarter = SyncHTTPHandler.maximumBodyBytes / 4
            let original = String(
                repeating: "a", count: kind == "intermediate" ? quarter * 2 : quarter)
            let record = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "known-authority-budget"),
                note: original)
            let peer = UUID()
            _ = try server.apply(
                SyncOperation(
                    deviceID: peer, sequence: 1, captureID: record.id, baseRevision: 0,
                    mutation: .create(record)))
            if kind != "intermediate" {
                _ = try server.apply(
                    SyncOperation(
                        deviceID: peer, sequence: 2, captureID: record.id, baseRevision: 0,
                        mutation: .edit(
                            CaptureEdit(note: NoteEdit(String(repeating: "b", count: quarter))))))
            }
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            try client.pull(from: transport)
            if kind != "intermediate" {
                try client.pull(from: transport)
                #expect(try client.cursor() == 2)
                #expect(try client.captures().first?.noteConflicts.count == 2)
            }
            let originalRecords = try client.captures()
            #expect(throws: SyncHTTPError.resourceLimit) {
                if kind == "intermediate" {
                    try store.dbPool.write { db in
                        try client.enqueue(
                            in: db,
                            edits: [
                                (
                                    record.id,
                                    CaptureEdit(
                                        generatedPatch: GeneratedContentPatch(
                                            body: .set(String(repeating: "x", count: quarter * 2))))
                                ),
                                (record.id, CaptureEdit(note: NoteEdit(nil))),
                            ])
                    }
                } else if kind == "conflict" {
                    try client.enqueue(
                        captureID: record.id,
                        mutation: .edit(
                            CaptureEdit(
                                note: NoteEdit(String(repeating: "c", count: quarter + quarter / 2))
                            )))
                } else {
                    let incoming = SharedCapture(
                        source: record.source,
                        note: String(repeating: "c", count: quarter + quarter / 2))
                    try client.enqueue(captureID: incoming.id, mutation: .create(incoming))
                }
            }
            let queued = try client.pendingOperations()
            let count = queued.count
            #expect(count == 0)
            #expect(try client.captures() == originalRecords)
            if let operation = queued.first {
                let principal = SyncPrincipal(
                    serviceID: binding.serviceID, libraryID: binding.libraryID,
                    deviceID: client.deviceID)
                let handler = SyncHTTPHandler(
                    serviceID: binding.serviceID,
                    authorizer: StoreBudgetAuthorizer(principal: principal), server: { _ in server }
                )
                let body = try JSONEncoder().encode(
                    SyncHTTPEnvelope(
                        version: 4, expectedServiceID: binding.serviceID,
                        expectedLibraryID: binding.libraryID, expectedDeviceID: client.deviceID,
                        action: .apply(operation)))
                let reply = try JSONDecoder().decode(
                    SyncHTTPReply.self,
                    from: handler.handle(
                        SyncHTTPRequest(
                            method: "POST", path: "/v1/sync",
                            headers: [
                                "Authorization": "Bearer synthetic-budget",
                                "Content-Type": "application/json",
                            ], body: body)
                    ).body)
                if case .failure(let error) = reply.result {
                    #expect(error == .resourceLimit)
                } else {
                    Issue.record("Oversized known authority reply was accepted")
                }
            }
        }
    }

    @Test(arguments: ["create", "edit", "generated", "batch"])
    func oversizedLocalWritesCannotBlockOutbox(kind: String) throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let half = String(repeating: "x", count: SyncHTTPHandler.maximumBodyBytes / 2)
            let capture = try store.upsertCapture(
                Capture(
                    kind: .link, url: "https://example.invalid/local-budget",
                    note: kind == "generated" ? half : nil,
                    body: kind == "generated" ? nil : half, contentHash: "local-budget",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            ).capture
            if kind == "generated" { _ = try store.claimForEnrichment(id: capture.id!) }
            let companion = try CaptureService(store: store).ingest(
                CaptureRequest(text: "Later safe change")
            ).capture
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            try client.push(to: transport)
            try client.pull(from: transport)
            let before = try store.reader.read {
                try Capture.fetchAll($0, sql: "SELECT * FROM captures ORDER BY id")
            }
            let sequence = try store.reader.read {
                try Int64.fetchOne($0, sql: "SELECT sequence FROM sync_meta")
            }
            let files = try FileManager.default.contentsOfDirectory(
                atPath: client.blobs.directory.path)
            #expect(throws: SyncHTTPError.self) {
                switch kind {
                case "create":
                    _ = try CaptureService(store: store).ingest(
                        CaptureRequest(text: "Oversized create", note: half + half + "over"))
                case "edit":
                    _ = try store.updateNote(id: capture.id!, note: half)
                case "generated":
                    _ = try store.completeEnrichment(
                        id: capture.id!,
                        result: StepResult(
                            bodyExtraction: BodyExtractionResult(
                                body: half, status: .ok, source: .fetch)), state: .ok)
                default:
                    try store.dbPool.write { db in
                        let ids = try [companion, capture].map {
                            try StoreSync.identity(db, capture: $0)
                        }
                        try client.enqueue(
                            in: db,
                            edits: [
                                (ids[0], CaptureEdit(note: NoteEdit("Partial batch"))),
                                (ids[1], CaptureEdit(note: NoteEdit(half))),
                            ])
                    }
                }
            }
            let queued = try client.pendingOperations()
            let queuedCount = queued.count
            #expect(queuedCount == 0)
            if !queued.isEmpty {
                let principal = SyncPrincipal(
                    serviceID: binding.serviceID, libraryID: binding.libraryID,
                    deviceID: client.deviceID)
                let handler = SyncHTTPHandler(
                    serviceID: binding.serviceID,
                    authorizer: StoreBudgetAuthorizer(principal: principal), server: { _ in server }
                )
                var refused = false
                for operation in queued {
                    let body = try JSONEncoder().encode(
                        SyncHTTPEnvelope(
                            version: 4, expectedServiceID: binding.serviceID,
                            expectedLibraryID: binding.libraryID, expectedDeviceID: client.deviceID,
                            action: .apply(operation)))
                    let response = handler.handle(
                        SyncHTTPRequest(
                            method: "POST", path: "/v1/sync",
                            headers: [
                                "Authorization": "Bearer synthetic-budget",
                                "Content-Type": "application/json",
                            ], body: body))
                    let reply = try JSONDecoder().decode(SyncHTTPReply.self, from: response.body)
                    if case .failure(let error) = reply.result {
                        #expect(error == .requestTooLarge || error == .resourceLimit)
                        refused = true
                        break
                    }
                }
                #expect(refused)
            }
            let after = try store.reader.read {
                try Capture.fetchAll($0, sql: "SELECT * FROM captures ORDER BY id")
            }
            #expect(after == before)
            #expect(
                try store.reader.read {
                    try Int64.fetchOne($0, sql: "SELECT sequence FROM sync_meta")
                } == sequence)
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: client.blobs.directory.path)
                    == files)
            _ = try store.updateNote(id: companion.id!, note: "Still sendable")
            try client.push(to: transport)
            #expect(try client.pendingOperations().isEmpty)
            #expect(try server.baseline().captures.contains { $0.note == "Still sendable" })
        }
    }

    @Test("Bulk synchronized deletion rebuilds once and rolls back an incomplete batch")
    func bulkDeletionProjectsOnceAndRollsBack() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let captures = try (1...3).map {
                try CaptureService(store: store).ingest(CaptureRequest(text: "Bulk delete \($0)"))
                    .capture
            }
            let ids = try captures.map { try #require($0.id) }
            let original = try client.pendingOperations()
            try store.dbPool.write { db in
                try db.execute(sql: "CREATE TABLE projection_count (id TEXT)")
                try db.execute(
                    sql:
                        "CREATE TRIGGER count_projection AFTER UPDATE ON sync_visible BEGIN INSERT INTO projection_count VALUES (NEW.id); END"
                )
                try db.execute(
                    sql:
                        "CREATE TRIGGER abort_second_delete BEFORE INSERT ON sync_outbox WHEN NEW.sequence=5 BEGIN SELECT RAISE(ABORT,'synthetic partial batch'); END"
                )
            }
            #expect(throws: (any Error).self) { try store.deleteCaptures(ids: ids) }
            #expect(try client.pendingOperations() == original)
            #expect(try store.reader.read { try Capture.fetchAll($0).count } == 3)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM projection_count")
                } == 0)
            try store.dbPool.write { try $0.execute(sql: "DROP TRIGGER abort_second_delete") }
            #expect(try store.deleteCaptures(ids: ids).count == 3)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM projection_count")
                } == 3)
            let operations = try client.pendingOperations()
            #expect(operations.map(\.sequence) == Array(1...6))
            #expect(
                operations.suffix(3).allSatisfy {
                    if case .delete = $0.mutation { return true }
                    return false
                })
            for operation in operations.suffix(3) {
                #expect(
                    operation.predecessorID
                        == original.first { $0.captureID == operation.captureID }?.id)
            }
            #expect(try client.captures().isEmpty)
            #expect(try client.captures(includeDeleted: true).allSatisfy(\.deleted))
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            try client.push(to: transport)
            try client.pull(from: transport)
            #expect(try client.pendingOperations().isEmpty)
            #expect(try server.baseline().captures.count == 3)
            #expect(try server.baseline().captures.allSatisfy(\.deleted))
        }
    }

    @Test("Conflict status uses compact projections and upgrades existing visible conflicts")
    func compactConflictProjection() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            let remoteDevice = UUID()
            var remote = SharedCapture(
                source: CaptureSource(kind: .text, title: "Indexed conflict"), note: "Original")
            remote.generated.body = String(repeating: "Large unrelated body ", count: 10_000)
            _ = try server.apply(
                SyncOperation(
                    deviceID: remoteDevice, sequence: 1, captureID: remote.id,
                    baseRevision: 0, mutation: .create(remote)))
            try client.pull(from: transport)
            #expect(try store.noteConflicts().isEmpty)
            let local = try #require(try store.reader.read { try Capture.fetchOne($0) })
            _ = try store.updateNote(id: local.id!, note: "Local")
            _ = try server.apply(
                SyncOperation(
                    deviceID: remoteDevice, sequence: 2, captureID: remote.id,
                    baseRevision: 1, mutation: .edit(CaptureEdit(note: NoteEdit("Remote")))))
            try client.push(to: transport)
            try client.pull(from: transport)
            let conflicts = try store.noteConflicts()
            #expect(conflicts.count == 1)
            let payload = try #require(
                try store.reader.read {
                    try Data.fetchOne($0, sql: "SELECT payload FROM sync_note_conflicts")
                })
            let fields = try #require(
                try JSONSerialization.jsonObject(with: payload) as? [String: Any])
            #expect(Set(fields.keys) == ["id", "title", "revision", "variants"])
            #expect(payload.count < 1_000)
            try store.dbPool.write { try $0.execute(sql: "DROP TABLE sync_note_conflicts") }
            let reopened = try Store(paths: paths, syncBinding: binding)
            #expect(try reopened.noteConflicts() == conflicts)
            let current = try #require(try server.baseline().captures.first)
            _ = try server.apply(
                SyncOperation(
                    deviceID: remoteDevice, sequence: 3, captureID: remote.id,
                    baseRevision: current.revision, mutation: .delete))
            try client.pull(from: transport)
            #expect(try store.noteConflicts().isEmpty)
            #expect(try reopened.noteConflicts().isEmpty)
            let tombstone = try #require(try server.baseline().captures.first)
            _ = try server.apply(
                SyncOperation(
                    deviceID: remoteDevice, sequence: 4, captureID: remote.id,
                    baseRevision: tombstone.revision, mutation: .restore))
            try client.pull(from: transport)
            #expect(try store.noteConflicts().count == 1)
            let restored = try #require(try server.baseline().captures.first)
            _ = try server.apply(
                SyncOperation(
                    deviceID: remoteDevice, sequence: 5, captureID: remote.id,
                    baseRevision: restored.revision, mutation: .delete))
            let deleted = try #require(try server.baseline().captures.first)
            #expect(deleted.deleted)
            try server.expireFeed(through: server.baseline().cursor)
            try client.pull(from: transport)
            #expect(try client.captures().isEmpty)
            #expect(try client.captures(includeDeleted: true) == [deleted])
            #expect(try store.noteConflicts().isEmpty)
            #expect(try reopened.noteConflicts().isEmpty)
        }
    }

    @Test("Same-body remote quality corrections win over active enrichment claims")
    func sameBodyQualityWinsOverStaleCompletion() throws {
        let corrections: [(Bool?, Bool)] = [
            (true, false), (false, true), (nil, true), (nil, false),
        ]
        for (initialQuality, correctedQuality) in corrections {
            try fixture { paths, binding, server in
                let store = try Store(paths: paths, syncBinding: binding)
                let client = try #require(store.syncClient)
                let transport = StoreTestTransport(
                    server: server, binding: binding, deviceID: client.deviceID)
                let remoteDevice = UUID()
                let body = "Same synchronized body"
                var remote = SharedCapture(
                    source: CaptureSource(kind: .link, url: "https://example.invalid/quality"))
                remote.generated = GeneratedContent(body: body, bodyIsThin: initialQuality)
                _ = try server.apply(
                    SyncOperation(
                        deviceID: remoteDevice, sequence: 1, captureID: remote.id,
                        baseRevision: 0, mutation: .create(remote)))
                try client.pull(from: transport)
                let local = try #require(try store.reader.read { try Capture.fetchOne($0) })
                try store.dbPool.write { db in
                    try db.execute(
                        sql: "UPDATE captures SET enrichment_state='pending' WHERE id=?",
                        arguments: [local.id])
                }
                let claim = try #require(try store.claimForEnrichment(id: local.id!))
                #expect(claim.claimedSyncBodyQuality != nil)
                #expect(claim.claimedSyncBodyQuality?.isThin == initialQuality)
                _ = try server.apply(
                    SyncOperation(
                        deviceID: remoteDevice, sequence: 2, captureID: remote.id,
                        baseRevision: 1,
                        mutation: .edit(
                            CaptureEdit(
                                generatedPatch: GeneratedContentPatch(bodyIsThin: correctedQuality))
                        )))
                try client.pull(from: transport)
                #expect(
                    try SearchService(store: store).capture(id: local.id!)?.enrichmentState
                        == .fetching)
                let staleStatus: BodyStatus = initialQuality == true ? .thin : .ok
                let completed = try store.completeEnrichment(
                    id: local.id!,
                    result: StepResult(
                        bodyExtraction: BodyExtractionResult(
                            body: body, status: staleStatus, source: .fetch)),
                    state: staleStatus == .thin ? .thin : .ok, expectedClaim: claim)
                #expect(completed.body == body)
                #expect(completed.bodyStatus == (correctedQuality ? .thin : .ok))
                #expect(completed.enrichmentState == (correctedQuality ? .thin : .ok))
                #expect(try client.pendingOperations().isEmpty)
                #expect(try client.captures().first?.generated.bodyIsThin == correctedQuality)
            }
        }
    }

    @Test("Conflict resolution freezes displayed IDs and revision while retaining unseen variants")
    func noteResolutionRetainsNewerVariants() throws {
        for pullNewVariant in [false, true] {
            try fixture { paths, binding, server in
                let store = try Store(paths: paths, syncBinding: binding)
                let client = try #require(store.syncClient)
                let transport = StoreTestTransport(
                    server: server, binding: binding, deviceID: client.deviceID)
                let captured = try CaptureService(store: store).ingest(
                    CaptureRequest(text: "Note conflict", note: "Original")
                ).capture
                try client.push(to: transport)
                let id = try #require(try server.baseline().captures.first?.id)
                _ = try store.updateNote(id: captured.id!, note: "Mac variant")
                _ = try server.apply(
                    SyncOperation(
                        deviceID: UUID(), sequence: 1, captureID: id, baseRevision: 1,
                        mutation: .edit(CaptureEdit(note: NoteEdit("Remote variant")))))
                try client.push(to: transport)
                try client.pull(from: transport)
                let snapshot = try #require(try store.noteConflicts().first)
                let originalIDs = snapshot.variants.map(\.operationID)
                let latest = try #require(try server.baseline().captures.first)
                _ = try server.apply(
                    SyncOperation(
                        deviceID: UUID(), sequence: 1, captureID: id, baseRevision: latest.revision,
                        mutation: .edit(CaptureEdit(note: NoteEdit("Unseen variant")))))
                if pullNewVariant { try client.pull(from: transport) }
                try store.resolveNoteConflict(snapshot, note: "  Merged note  ")
                let operation = try #require(try client.pendingOperations().first)
                #expect(operation.captureID == snapshot.id)
                #expect(operation.baseRevision == snapshot.revision)
                guard case .edit(let edit) = operation.mutation else {
                    Issue.record("Expected a resolution edit")
                    return
                }
                #expect(edit.note?.resolving == originalIDs)
                #expect(edit.note?.value == "Merged note")
                #expect(try client.push(to: transport).first?.outcome == .noteConflict)
                try client.pull(from: transport)
                let remaining = try #require(try store.noteConflicts().first)
                #expect(
                    Set(remaining.variants.compactMap(\.value)) == [
                        "Mac variant", "Remote variant", "Unseen variant", "Merged note",
                    ])
                try store.resolveNoteConflict(remaining, note: " \n ")
                try client.push(to: transport)
                try client.pull(from: transport)
                #expect(try store.noteConflicts().isEmpty)
                #expect(try SearchService(store: store).capture(id: captured.id!)?.note == nil)
                #expect(throws: MacSyncError.noteConflictChanged) {
                    try store.resolveNoteConflict(snapshot, note: "Obsolete resolution")
                }
                #expect(try client.pendingOperations().isEmpty)
            }
        }
    }

    @Test("Resolution refuses empty or foreign conflict snapshots without changing the capture")
    func invalidNoteResolutionSnapshot() throws {
        try fixture { paths, binding, _ in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let capture = try CaptureService(store: store).ingest(
                CaptureRequest(text: "Unrelated", note: "Keep note")
            ).capture
            let pending = try client.pendingOperations()
            for variants in [[], [NoteVariant(operationID: UUID(), value: "Foreign note")]] {
                let snapshot = MacNoteConflict(
                    id: UUID(), title: "Foreign", revision: 1, variants: variants)
                #expect(throws: MacSyncError.noteConflictChanged) {
                    try store.resolveNoteConflict(snapshot, note: "Never written")
                }
            }
            #expect(try SearchService(store: store).capture(id: capture.id!)?.note == "Keep note")
            #expect(try client.pendingOperations() == pending)
        }
    }
    @Test("Thin extraction remains retryable locally, on peers and through same-body corrections")
    func thinExtractionQuality() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let service = CaptureService(store: store)
            let request = CaptureRequest(url: "https://example.invalid/login")
            let capture = try service.ingest(request).capture
            _ = try store.claimForEnrichment(id: capture.id!)
            let body = "Sign in to continue reading"
            _ = try store.completeEnrichment(
                id: capture.id!,
                result: StepResult(
                    bodyExtraction: BodyExtractionResult(body: body, status: .thin, source: .fetch)),
                state: .thin)
            let local = try #require(try SearchService(store: store).capture(id: capture.id!))
            #expect(local.body == body)
            #expect(local.bodyStatus == .thin)
            #expect(local.enrichmentState == .thin)
            #expect(StoreSync.snapshot(local, id: UUID()).generated.bodyIsThin == true)
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            try client.push(to: transport)
            let peerPaths = StoragePaths(root: paths.root.appendingPathComponent("quality-peer"))
            let peer = try Store(paths: peerPaths, syncBinding: binding)
            let peerClient = try #require(peer.syncClient)
            let peerTransport = StoreTestTransport(
                server: server, binding: binding, deviceID: peerClient.deviceID)
            try peerClient.pull(from: peerTransport)
            let received = try #require(try peer.reader.read { try Capture.fetchOne($0) })
            #expect(received.bodyStatus == .thin)
            #expect(received.enrichmentState == .thin)
            #expect(
                try CaptureService(store: peer).ingest(request).capture.enrichmentState == .pending)
            #expect(try service.ingest(request).capture.enrichmentState == .pending)
            _ = try store.claimForEnrichment(id: capture.id!)
            _ = try store.completeEnrichment(
                id: capture.id!,
                result: StepResult(
                    bodyExtraction: BodyExtractionResult(body: body, status: .ok, source: .fetch)),
                state: .ok)
            #expect(
                try client.pendingOperations().contains { operation in
                    guard case .edit(let edit) = operation.mutation else { return false }
                    return edit.generatedPatch?.body == nil
                        && edit.generatedPatch?.bodyIsThin == false
                })
            try client.push(to: transport)
            try peerClient.push(to: peerTransport)
            try peerClient.pull(from: peerTransport)
            let corrected = try #require(try SearchService(store: peer).capture(id: received.id!))
            #expect(corrected.body == body)
            #expect(corrected.bodyStatus == .ok)
            #expect(corrected.enrichmentState == .ok)
        }
    }

    @Test("Incoming thin or empty bodies retain their quality through stale enrichment completion")
    func incomingThinBodyWinsOverStaleCompletion() throws {
        for (body, isThin) in [("Remote login wall", true), ("", false)] {
            try fixture { paths, binding, server in
                let store = try Store(paths: paths, syncBinding: binding)
                let client = try #require(store.syncClient)
                let local = try CaptureService(store: store).ingest(
                    CaptureRequest(url: "https://example.invalid/race")
                ).capture
                let transport = StoreTestTransport(
                    server: server, binding: binding, deviceID: client.deviceID)
                try client.push(to: transport)
                let claim = try #require(try store.claimForEnrichment(id: local.id!))
                let shared = try #require(try server.baseline().captures.first)
                _ = try server.apply(
                    SyncOperation(
                        deviceID: UUID(), sequence: 1, captureID: shared.id,
                        baseRevision: shared.revision,
                        mutation: .edit(
                            CaptureEdit(
                                generatedPatch: GeneratedContentPatch(
                                    body: .set(body), bodyIsThin: isThin)))))
                try client.pull(from: transport)
                let completed = try store.completeEnrichment(
                    id: local.id!,
                    result: StepResult(
                        bodyExtraction: BodyExtractionResult(
                            body: "Stale healthy body", status: .ok, source: .fetch)), state: .ok,
                    expectedClaim: claim)
                #expect(completed.body == body)
                #expect(completed.bodyStatus == .thin)
                #expect(completed.enrichmentState == .thin)
                #expect(try client.pendingOperations().isEmpty)
            }
        }
    }

    @Test("Oversized synced images fail before writing assets or allocating outbox sequences")
    func oversizedImageLeavesNoAsset() throws {
        try fixture { paths, binding, _ in
            let store = try Store(paths: paths, syncBinding: binding)
            let bytes = Data(repeating: 0x5a, count: 8_388_609)
            let filesBefore = try FileManager.default.subpathsOfDirectory(
                atPath: paths.assetsDirectory.path
            ).sorted()
            #expect(throws: CaptureError.imageTooLarge) {
                try CaptureService(store: store).ingest(CaptureRequest(imageData: bytes))
            }
            #expect(try SearchService(store: store).totalCaptureCount() == 0)
            #expect(try store.syncClient?.pendingOperations().isEmpty == true)
            #expect(
                try FileManager.default.subpathsOfDirectory(atPath: paths.assetsDirectory.path)
                    .sorted() == filesBefore)
            let accepted = try CaptureService(store: store).ingest(
                CaptureRequest(imageData: bytes.prefix(8_388_608))
            ).capture
            #expect(accepted.assetPath != nil)
            #expect(try store.syncClient?.pendingOperations().map(\.sequence) == [1])
            let local = try Store(
                paths: StoragePaths(root: paths.root.appendingPathComponent("unbound")))
            #expect(
                try CaptureService(store: local).ingest(CaptureRequest(imageData: bytes)).capture
                    .assetPath != nil)
        }
    }

    @Test("Taxonomy revision rebuilds the library once per batch and keeps manual tags")
    func taxonomyRevisionProjectsOncePerBatch() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let remote = UUID()
            for index in 1...30 {
                var record = SharedCapture(
                    source: CaptureSource(kind: .text, contentHash: "revision-\(index)"))
                record.manualTags = ["manual"]
                record.generated = GeneratedContent(
                    tags: [index.isMultiple(of: 2) ? "keep" : "drop"], taggingProcessed: true,
                    taggingInputFingerprint: "old")
                _ = try server.apply(
                    SyncOperation(
                        deviceID: remote, sequence: Int64(index), captureID: record.id,
                        baseRevision: 0, mutation: .create(record)))
            }
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            try client.pull(from: transport)
            try store.dbPool.write { db in
                try db.execute(sql: "CREATE TABLE revision_writes (id INTEGER)")
                try db.execute(
                    sql:
                        "CREATE TRIGGER audit_revision AFTER UPDATE ON captures BEGIN INSERT INTO revision_writes VALUES (NEW.id); END"
                )
            }
            try store.applyTaxonomyRevision(
                mapping: ["keep": "renamed"],
                taxonomy: Taxonomy(version: 2, tags: ["renamed"], updatedAt: Date()),
                batchSize: 10)
            #expect(try client.pendingOperations().count == 30)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM revision_writes")
                } == 120)
            let records = try client.captures()
            #expect(records.allSatisfy { $0.manualTags == ["manual"] })
            #expect(records.filter { $0.generated.tags == ["renamed"] }.count == 15)
            #expect(
                records.filter {
                    $0.generated.tags.isEmpty && $0.generated.taggingProcessed == false
                }.count == 15)
            try client.push(to: transport)
            let committed = try server.baseline().captures
            #expect(committed.allSatisfy { $0.manualTags == ["manual"] })
            #expect(committed.filter { $0.generated.tags == ["renamed"] }.count == 15)
            #expect(
                committed.filter {
                    $0.generated.tags.isEmpty && $0.generated.taggingProcessed == false
                }.count == 15)
        }
    }
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
            let samples = try store.retaggingSamples(limit: 10)
            #expect(Set(samples.compactMap(\.id)) == Set([link.id!, second.id!]))
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

    @Test("Remote content refreshes terminal enrichment while retaining active claims")
    func terminalEnrichmentRefreshes() throws {
        try fixture { paths, binding, _ in
            let store = try Store(paths: paths, syncBinding: binding)
            for kind in [CaptureKind.link, .image] {
                for initial in [EnrichmentState.failed, .thin, .fetching] {
                    var record = SharedCapture(
                        source: CaptureSource(kind: kind == .link ? .link : .image),
                        createdAt: Date())
                    record.generated = GeneratedContent(
                        body: kind == .link ? "Remote usable body" : nil,
                        ocrText: kind == .image ? "Remote usable OCR" : nil)
                    let projected = try store.dbPool.write { db -> Capture in
                        var original = Capture(
                            kind: kind, enrichmentState: initial, bodyStatus: .failed,
                            createdAt: record.createdAt)
                        try original.insert(db)
                        try db.execute(
                            sql: "INSERT INTO sync_capture_ids VALUES (?,?)",
                            arguments: [original.id, record.id.uuidString])
                        try StoreSync.project(db, record: record, paths: paths)
                        return try #require(try Capture.fetchOne(db, key: original.id!))
                    }
                    #expect(projected.body == record.generated.body)
                    #expect(projected.ocrText == record.generated.ocrText)
                    #expect(projected.enrichmentState == (initial == .fetching ? .fetching : .ok))
                    if kind == .link {
                        #expect(projected.bodyStatus == (initial == .fetching ? .failed : .ok))
                    }
                }
            }
        }
    }

    @Test("Unchanged remote OCR preserves a requested refresh")
    func unchangedOCRPreservesRefresh() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            let remoteDevice = UUID()
            let bytes = Data("Synthetic OCR image".utf8)
            let blob = BlobReference(data: bytes)
            try server.upload(blob, offset: 0, chunk: bytes, final: true)
            var record = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
            record.generated = GeneratedContent(ocrText: "Existing OCR")
            _ = try server.apply(
                SyncOperation(
                    deviceID: remoteDevice, sequence: 1, captureID: record.id,
                    baseRevision: 0, mutation: .create(record)))
            try client.pull(from: transport)
            let local = try #require(try store.reader.read { try Capture.fetchOne($0) })
            #expect(try store.requeueCaptures(ids: [local.id!]) == 1)
            try client.pull(from: transport)
            #expect(
                try SearchService(store: store).capture(id: local.id!)?.enrichmentState == .pending)
            _ = try server.apply(
                SyncOperation(
                    deviceID: remoteDevice, sequence: 2, captureID: record.id,
                    baseRevision: 1,
                    mutation: .edit(
                        CaptureEdit(generatedPatch: GeneratedContentPatch(ocrText: .set("New OCR")))
                    )
                ))
            try client.pull(from: transport)
            #expect(try SearchService(store: store).capture(id: local.id!)?.enrichmentState == .ok)
            #expect(try store.requeueCaptures(ids: [local.id!]) == 1)
            try client.pull(from: transport)
            #expect(try store.claimForEnrichment(id: local.id!) != nil)
        }
    }

    @Test("Remote content clears requeue terminal captures while retaining active claims")
    func clearedContentRequeues() throws {
        try fixture { paths, binding, _ in
            let store = try Store(paths: paths, syncBinding: binding)
            for kind in [CaptureKind.link, .image] {
                for initial in [EnrichmentState.ok, .thin, .fetching] {
                    let record = SharedCapture(
                        source: CaptureSource(kind: kind == .link ? .link : .image),
                        createdAt: Date())
                    let projected = try store.dbPool.write { db -> Capture in
                        var original = Capture(
                            kind: kind, body: kind == .link ? "Old body" : nil,
                            ocrText: kind == .image ? "Old OCR" : nil, enrichmentState: initial,
                            bodyStatus: .ok, bodySource: .fetch, createdAt: record.createdAt)
                        try original.insert(db)
                        try db.execute(
                            sql: "INSERT INTO sync_capture_ids VALUES (?,?)",
                            arguments: [original.id, record.id.uuidString])
                        try StoreSync.project(db, record: record, paths: paths)
                        return try #require(try Capture.fetchOne(db, key: original.id!))
                    }
                    #expect(projected.body == nil)
                    #expect(projected.ocrText == nil)
                    #expect(
                        projected.enrichmentState == (initial == .fetching ? .fetching : .pending))
                    if kind == .link && initial != .fetching {
                        #expect(projected.bodyStatus == .none)
                        #expect(projected.bodySource == nil)
                        #expect(try store.claimForEnrichment(id: projected.id!) != nil)
                    }
                }
            }
        }
    }

    @Test("Bulk retagging projects every capture once after all operations are enqueued")
    func bulkRetagProjectsOnce() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let client = try #require(store.syncClient)
            let remote = UUID()
            for index in 1...30 {
                var record = SharedCapture(
                    source: CaptureSource(kind: .text, contentHash: "retag-\(index)"))
                record.manualTags = ["manual"]
                record.generated.tags = ["generated"]
                _ = try server.apply(
                    SyncOperation(
                        deviceID: remote, sequence: Int64(index),
                        captureID: record.id, baseRevision: 0, mutation: .create(record)))
            }
            let transport = StoreTestTransport(
                server: server, binding: binding, deviceID: client.deviceID)
            try client.pull(from: transport)
            try store.dbPool.write { db in
                try db.execute(sql: "CREATE TABLE retag_writes (id INTEGER)")
                try db.execute(
                    sql:
                        "CREATE TRIGGER audit_retag AFTER UPDATE ON captures BEGIN INSERT INTO retag_writes VALUES (NEW.id); END"
                )
            }
            try store.requestRetagging()
            #expect(try store.prepareRetagging(tags: ["new"]) == 30)
            #expect(try client.pendingOperations().count == 30)
            #expect(
                try store.reader.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM retag_writes")
                } == 60)
            #expect(
                try client.captures().allSatisfy {
                    $0.manualTags == ["manual"] && $0.generated.tags.isEmpty
                        && $0.generated.taggingProcessed == false
                })
            try client.push(to: transport)
            #expect(
                try server.baseline().captures.allSatisfy {
                    $0.manualTags == ["manual"] && $0.generated.tags.isEmpty
                })
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
                createdAt: Date(timeIntervalSince1970: 1_600_000_000))
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
            #expect(receipt.capture?.createdAt == canonical.createdAt)
            #expect(original.captureID != canonical.id)
            try client.pull(from: transport)
            let projected = try #require(try SearchService(store: store).capture(id: local.id!))
            #expect(projected.seenCount == 2)
            #expect(projected.id == local.id)
            #expect(projected.createdAt == canonical.createdAt)
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
            try client.push(to: transport)
            try client.pull(from: transport)
            #expect(try server.baseline().captures.first?.createdAt == canonical.createdAt)
            #expect(try client.captures().first?.createdAt == canonical.createdAt)
            #expect(
                try SearchService(store: store).capture(id: local.id!)?.createdAt
                    == canonical.createdAt)
            let reopened = try Store(paths: paths, syncBinding: binding)
            let retained = try #require(try SearchService(store: reopened).capture(id: local.id!))
            #expect(retained.id == local.id)
            #expect(retained.createdAt == canonical.createdAt)
            #expect(try reopened.syncClient?.pendingOperations().isEmpty == true)
        }
    }

    @Test("An existing aliased projection adopts the accepted immutable creation time")
    func existingAliasProjectionUsesCanonicalCreationTime() throws {
        try fixture { paths, binding, server in
            let store = try Store(paths: paths, syncBinding: binding)
            let local = try CaptureService(store: store).ingest(
                CaptureRequest(
                    text: "Retained alias source",
                    capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
            ).capture
            let client = try #require(store.syncClient)
            let operation = try #require(try client.pendingOperations().first)
            let pending = try store.reader.read {
                try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
            }
            let canonical = SharedCapture(
                source: CaptureSource(
                    kind: .text, contentHash: local.contentHash, selection: local.selection),
                createdAt: Date(timeIntervalSince1970: 1_600_000_000))
            let receipt = try server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: canonical.id, baseRevision: 0,
                    mutation: .create(canonical)))
            let accepted = try #require(receipt.capture)
            #expect(accepted.revision == 1)
            try store.dbPool.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_aliases (id,canonical) VALUES (?,?)",
                    arguments: [operation.captureID.uuidString, accepted.id.uuidString])
                try StoreSync.project(db, record: accepted, paths: paths)
            }
            let projected = try #require(try SearchService(store: store).capture(id: local.id!))
            #expect(projected.id == local.id)
            #expect(projected.createdAt == accepted.createdAt)
            let exported = StoreSync.snapshot(projected, id: accepted.id)
            #expect(exported.id == accepted.id)
            #expect(exported.source == accepted.source)
            #expect(exported.createdAt == accepted.createdAt)
            #expect(try store.reader.read { try Capture.fetchCount($0) } == 1)
            #expect(
                try store.reader.read {
                    try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
                } == pending)
            let reopened = try Store(paths: paths, syncBinding: binding)
            #expect(
                try SearchService(store: reopened).capture(id: local.id!)?.createdAt
                    == accepted.createdAt)
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

private struct StoreBudgetAuthorizer: SyncAuthorizer {
    let principal: SyncPrincipal
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        bearerCredential == "synthetic-budget" ? principal : nil
    }
}

private struct StoreSnapshotTransport: BoundSyncTransport {
    let base: StoreTestTransport
    let snapshot: Baseline
    var binding: SyncLibraryBinding { base.binding }
    var deviceID: UUID { base.deviceID }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt { try base.apply(operation) }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        throw SyncError.cursorExpired
    }
    func baseline() throws -> Baseline { snapshot }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try base.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try base.download(blob) }
}

private final class StorePartialPushTransport: BoundSyncTransport {
    let base: SyncHTTPTransport
    private let calls = Mutex(0)
    init(base: SyncHTTPTransport) { self.base = base }
    var binding: SyncLibraryBinding { base.binding }
    var deviceID: UUID { base.deviceID }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        let count = calls.withLock {
            $0 += 1
            return $0
        }
        guard count == 1 else { throw SyncError.transportDisconnected }
        return try base.apply(operation)
    }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try base.changes(after: cursor, limit: limit)
    }
    func baseline() throws -> Baseline { try base.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try base.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try base.download(blob) }
}
