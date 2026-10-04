import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdKit

@Suite("Opt-in Mac Store sync")
struct StoreSyncTests {
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
                    baseRevision: restored.revision, mutation: .recapture))
            let authority = try DatabaseQueue(
                path: paths.root.deletingLastPathComponent().appendingPathComponent(
                    "authority.sqlite"
                ).path)
            try authority.write { db in
                try db.execute(
                    sql: "DELETE FROM sync_records WHERE id=?", arguments: [remote.id.uuidString])
            }
            try server.expireFeed(through: server.baseline().cursor)
            try client.pull(from: transport)
            #expect(try client.captures().isEmpty)
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
