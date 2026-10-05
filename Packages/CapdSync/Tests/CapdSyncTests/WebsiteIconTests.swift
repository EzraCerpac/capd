import Foundation
import GRDB
import Testing

@testable import CapdSync

@Suite("Independent website icon sync")
struct WebsiteIconTests {
    @Test(arguments: [
        "https://www.capd.dev/path?a=b#c", "HTTPS://WWW.CAPD.DEV:443/", "https://www.capd.dev",
    ])
    func originCanonicalization(_ url: String) throws {
        let origin = try #require(WebsiteIconOrigin(url: url))
        #expect(origin.canonicalHTTPSOrigin == "https://www.capd.dev")
        #expect(origin.host == "www.capd.dev")
        #expect(origin.id != WebsiteIconOrigin(url: "https://capd.dev")!.id)
        #expect(
            try SyncDatabase.decode(WebsiteIconOrigin.self, SyncDatabase.encode(origin)) == origin)
    }

    @Test(arguments: [
        "http://capd.dev", "https://user@capd.dev", "https://capd.dev:444", "https://127.0.0.1",
        "https://[::1]", "https://localhost", "https://a.local", "https://a.internal",
        "https://a.onion", "https://capd.dev.", "https://a..dev", "https://2130706433",
        "https://0177.0.0.1", "https://a.invalid", "https://a.example", "https://0x7f.0.0.0x1",
    ])
    func originRefusal(_ url: String) {
        #expect(WebsiteIconOrigin(url: url) == nil)
    }

    @Test func originDecoderRejectsNoncanonical() {
        #expect(throws: DecodingError.self) {
            try SyncDatabase.decode(
                WebsiteIconOrigin.self,
                Data(#"{"canonicalHTTPSOrigin":"https://CAPD.dev/path"}"#.utf8))
        }
    }

    @Test func crossDeviceWireOfflineReopenAndIndependentLanes() async throws {
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        let b = try f.client("b", device: f.b)
        let capture = f.capture()
        try a.enqueue(captureID: capture.id, mutation: .create(capture))
        try a.push(to: f.transport(f.a))
        try b.pull(from: f.transport(f.b))
        let captureBaseline = try f.server.baseline()
        let blob = try a.blobs.put(iconPNG)
        let operation = try a.enqueueWebsiteIcon(
            origin: f.origin,
            mutation: .upsert(
                WebsiteIconContent(blob: blob, fetchedAt: Date(timeIntervalSince1970: 1))))
        #expect(operation.sequence == 1)
        #expect(try a.websiteIconRevision() == 1)
        try await a.pushWebsiteIcons(to: f.asyncTransport(f.a), credential: { f.a.uuidString })
        try await b.pullWebsiteIcons(from: f.asyncTransport(f.b), credential: { f.b.uuidString })
        #expect(try f.server.baseline() == captureBaseline)
        #expect(try b.pendingOperations().isEmpty)
        #expect(try b.websiteIconCursor() == 1)
        let record = try #require(try b.websiteIcon(originID: f.origin.id))
        #expect(record.revision == 1 && !record.deleted)
        #expect(try b.blobs.read(blob) == iconPNG)
        let reopened = try f.client("b", device: f.b)
        #expect(try reopened.websiteIcon(originID: f.origin.id) == record)
        #expect(try reopened.blobs.read(blob) == iconPNG)
        #expect(try reopened.websiteIconRevision() == b.websiteIconRevision())
    }

    @Test func lostAcknowledgementAndLastLiveOriginLifecycle() throws {
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        let first = f.capture()
        let second = f.capture(path: "/second")
        for capture in [first, second] {
            try a.enqueue(captureID: capture.id, mutation: .create(capture))
        }
        try a.push(to: f.transport(f.a))
        try a.pull(from: f.transport(f.a))
        let blob = try a.blobs.put(iconPNG)
        let op = try a.enqueueWebsiteIcon(
            origin: f.origin,
            mutation: .upsert(
                WebsiteIconContent(blob: blob, fetchedAt: Date(timeIntervalSince1970: 1))))
        try f.transport(f.a).uploadWebsiteIcon(blob, offset: 0, chunk: iconPNG, final: true)
        let receipt = try f.transport(f.a).applyWebsiteIcon(op)
        try a.enqueue(captureID: first.id, mutation: .delete)
        try a.push(to: f.transport(f.a))
        #expect(try f.server.websiteIconBaseline().records.first?.deleted == false)
        try a.enqueue(captureID: second.id, mutation: .delete)
        try a.push(to: f.transport(f.a))
        let tombstone = try #require(f.server.websiteIconBaseline().records.first)
        #expect(tombstone.deleted && tombstone.revision == 2 && tombstone.content?.blob == blob)
        #expect(try f.transport(f.a).applyWebsiteIcon(op) == receipt)
        try a.pullWebsiteIcons(from: f.transport(f.a))
        let reopened = try f.client("a", device: f.a)
        try reopened.pushWebsiteIcons(to: f.transport(f.a))
        #expect(try reopened.pendingWebsiteIconOperations().isEmpty)
        #expect(try reopened.websiteIcon(originID: f.origin.id) == tombstone)
        try reopened.pull(from: f.transport(f.a))
        let deleted = try #require(
            reopened.captures(includeDeleted: true).first { $0.id == second.id })
        try reopened.enqueue(
            captureID: second.id, mutation: .restore, baseRevision: deleted.revision)
        try reopened.push(to: f.transport(f.a))
        #expect(try f.server.websiteIconBaseline().records.first == tombstone)
        try reopened.enqueueWebsiteIcon(
            origin: f.origin,
            mutation: .upsert(
                WebsiteIconContent(blob: blob, fetchedAt: Date(timeIntervalSince1970: 2))))
        try reopened.pushWebsiteIcons(to: f.transport(f.a))
        #expect(try f.server.websiteIconBaseline().records.first?.deleted == false)
    }

    @Test func staleAndUnreferencedOperationsConsumeOnlyIconSequence() throws {
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        let capture = f.capture()
        try a.enqueue(captureID: capture.id, mutation: .create(capture))
        try a.push(to: f.transport(f.a))
        let blob = try a.blobs.put(iconPNG)
        try a.enqueueWebsiteIcon(
            origin: f.origin, mutation: .upsert(WebsiteIconContent(blob: blob)))
        try a.pushWebsiteIcons(to: f.transport(f.a))
        let stale = WebsiteIconOperation(
            deviceID: f.b, sequence: 1, origin: f.origin, baseRevision: 0,
            mutation: .upsert(WebsiteIconContent(blob: blob)))
        #expect(try f.transport(f.b).applyWebsiteIcon(stale).outcome == .stale)
        let unused = WebsiteIconOrigin(url: "https://unused.capd.dev")!
        let unreferenced = WebsiteIconOperation(
            deviceID: f.b, sequence: 2, origin: unused, baseRevision: 0,
            mutation: .upsert(WebsiteIconContent(blob: blob)))
        #expect(try f.transport(f.b).applyWebsiteIcon(unreferenced).outcome == .unreferenced)
        #expect(try f.server.websiteIconBaseline().cursor == 1)
        #expect(try f.server.websiteIconBaseline().deviceSequences[f.b] == 2)
        #expect(try f.server.baseline().deviceSequences[f.b] == nil)
        #expect(try f.transport(f.b).applyWebsiteIcon(unreferenced).outcome == .unreferenced)
        let reused = WebsiteIconOperation(
            id: stale.id, deviceID: f.b, sequence: 1, origin: unused, baseRevision: 0,
            mutation: .tombstone)
        #expect(throws: SyncError.operationIDReused) {
            try f.transport(f.b).applyWebsiteIcon(reused)
        }
    }

    @Test func namespaceIsLazyAndPendingIsImmutable() throws {
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        #expect(try a.websiteIconRevision() == 0)
        #expect(try a.websiteIcons().isEmpty)
        #expect(try a.writer.read { try !$0.tableExists("sync_website_icon_meta") })
        let blob = try a.blobs.put(iconPNG)
        let op = try a.enqueueWebsiteIcon(
            origin: f.origin, mutation: .upsert(WebsiteIconContent(blob: blob)))
        #expect(throws: WebsiteIconError.pendingOperation) {
            try a.enqueueWebsiteIcon(origin: f.origin, mutation: .tombstone)
        }
        #expect(try a.pendingWebsiteIconOperations() == [op])
        let other = try DatabaseQueue()
        #expect(throws: SyncTransactionError.wrongWriter) {
            try other.write {
                try a.enqueueWebsiteIcon(in: $0, origin: f.origin, mutation: .tombstone)
            }
        }
        #expect(throws: SyncTransactionError.requiresTransaction) {
            try a.writer.writeWithoutTransaction {
                try a.enqueueWebsiteIcon(in: $0, origin: f.origin, mutation: .tombstone)
            }
        }
    }

    @Test func pngEnvelopeRefusesPoisonAndAtomicAdmission() throws {
        try WebsiteIconPNG.validate(iconPNG)
        for bytes in [
            Data("not PNG".utf8), iconPNG.dropLast(), Data(iconPNG.prefix(20)),
            Data(repeating: 0, count: 262145),
        ] {
            #expect(throws: SyncError.invalidBlob) { try WebsiteIconPNG.validate(Data(bytes)) }
        }
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        var poison = iconPNG
        poison[40] ^= 1
        let blob = try a.blobs.put(poison)
        #expect(throws: SyncError.invalidBlob) {
            try a.enqueueWebsiteIcon(
                origin: f.origin, mutation: .upsert(WebsiteIconContent(blob: blob)))
        }
        #expect(try a.pendingWebsiteIconOperations().isEmpty)
        #expect(try a.websiteIconRevision() == 0)
        let valid = try a.blobs.put(iconPNG)
        let op = try a.enqueueWebsiteIcon(
            origin: f.origin, mutation: .upsert(WebsiteIconContent(blob: valid)))
        #expect(op.sequence == 1)
    }
    @Test(arguments: [false, true], [false, true])
    func capabilityRefusalBeforeUploadAndDowngradeOnEveryReply(asynchronous: Bool, downgrade: Bool)
        async throws
    {
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        let blob = try a.blobs.put(iconPNG)
        let op = try a.enqueueWebsiteIcon(
            origin: f.origin, mutation: .upsert(WebsiteIconContent(blob: blob)))
        let calls = IconCounter()
        let execute: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse = { request in
            let action = try SyncDatabase.decode(SyncHTTPEnvelope.self, request.body).action
            if case .uploadWebsiteIcon = action { calls.increment() }
            let response = f.handler(f.a).handle(request)
            let reply = try SyncDatabase.decode(SyncHTTPReply.self, response.body)
            let iconVersion =
                (!downgrade || action.requiresWebsiteIconContract)
                ? nil : reply.websiteIconContractVersion
            let changed = SyncHTTPReply(
                version: reply.version, principal: reply.principal, result: reply.result,
                metadataContractVersion: reply.metadataContractVersion,
                generatedProcessingContractVersion: reply.generatedProcessingContractVersion,
                extractionQualityContractVersion: reply.extractionQualityContractVersion,
                websiteIconContractVersion: iconVersion)
            return SyncHTTPResponse(
                status: response.status, headers: response.headers,
                body: try SyncDatabase.encode(changed))
        }
        if asynchronous {
            await #expect(throws: SyncHTTPError.unsupportedVersion) {
                try await a.pushWebsiteIcons(
                    to: IconClosureAsyncTransport(
                        binding: f.binding, deviceID: f.a, execute: execute),
                    credential: { f.a.uuidString })
            }
        } else {
            #expect(throws: SyncHTTPError.unsupportedVersion) {
                try a.pushWebsiteIcons(
                    to: SyncHTTPTransport(
                        binding: f.binding, deviceID: f.a, credential: { f.a.uuidString },
                        execute: execute))
            }
        }
        #expect(calls.value == 0)
        #expect(try a.pendingWebsiteIconOperations() == [op])
        #expect(try a.websiteIconCursor() == 0)
        #expect(try f.server.websiteIconBaseline().deviceSequences.isEmpty)
    }

    @Test func expiredBaselineOmissionRejectedBeforeCachingAndLegitimateRecoveryWorks() throws {
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        let b = try f.client("b", device: f.b)
        let capture = f.capture()
        try a.enqueue(captureID: capture.id, mutation: .create(capture))
        try a.push(to: f.transport(f.a))
        let blob = try a.blobs.put(iconPNG)
        try a.enqueueWebsiteIcon(
            origin: f.origin, mutation: .upsert(WebsiteIconContent(blob: blob)))
        try a.pushWebsiteIcons(to: f.transport(f.a))
        try b.pullWebsiteIcons(from: f.transport(f.b))
        try a.enqueueWebsiteIcon(
            origin: f.origin,
            mutation: .upsert(
                WebsiteIconContent(blob: blob, fetchedAt: Date(timeIntervalSince1970: 2))))
        try a.pushWebsiteIcons(to: f.transport(f.a))
        try f.server.expireWebsiteIconFeed()
        let records = try b.websiteIcons(includeDeleted: true)
        let epoch = try b.websiteIconRevision()
        let downloads = IconCounter()
        let malformed = SyncHTTPTransport(
            binding: f.binding, deviceID: f.b, credential: { f.b.uuidString },
            execute: { request in
                let action = try SyncDatabase.decode(SyncHTTPEnvelope.self, request.body).action
                if case .downloadWebsiteIcon = action { downloads.increment() }
                let response = f.handler(f.b).handle(request)
                let reply = try SyncDatabase.decode(SyncHTTPReply.self, response.body)
                guard case .websiteIconBaseline(let baseline) = reply.result else {
                    return response
                }
                let replacement = WebsiteIconBaseline(
                    cursor: baseline.cursor, captureCursor: baseline.captureCursor, records: [],
                    deviceSequences: baseline.deviceSequences, totalIconCount: 0)
                return SyncHTTPResponse(
                    status: response.status, headers: response.headers,
                    body: try SyncDatabase.encode(
                        SyncHTTPResponseBudget.replyPayload(
                            .websiteIconBaseline(replacement), principal: reply.principal)))
            })
        #expect(throws: SyncError.invalidCursor) { try b.pullWebsiteIcons(from: malformed) }
        #expect(try b.websiteIconCursor() == 1)
        #expect(try b.websiteIcons(includeDeleted: true) == records)
        #expect(try b.websiteIconRevision() == epoch)
        #expect(downloads.value == 0)
        try b.pullWebsiteIcons(from: f.transport(f.b))
        #expect(try b.websiteIconCursor() == 2)
        #expect(
            try b.websiteIcon(originID: f.origin.id)?.content?.fetchedAt
                == Date(timeIntervalSince1970: 2))
    }

    @Test func snapshotV2TargetWinsAndV1OmissionPreservesIcons() throws {
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        let capture = f.capture()
        try a.enqueue(captureID: capture.id, mutation: .create(capture))
        try a.push(to: f.transport(f.a))
        let blob = try a.blobs.put(iconPNG)
        try a.enqueueWebsiteIcon(
            origin: f.origin,
            mutation: .upsert(
                WebsiteIconContent(blob: blob, fetchedAt: Date(timeIntervalSince1970: 9))))
        try a.pushWebsiteIcons(to: f.transport(f.a))
        let original = try #require(try f.server.websiteIconBaseline().records.first)
        let incoming = WebsiteIconRecord(
            origin: f.origin, revision: 0,
            content: WebsiteIconContent(blob: blob, fetchedAt: Date(timeIntervalSince1970: 1)))
        let snapshot = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: f.binding, sourceDeviceID: UUID(),
            captures: [capture], websiteIcons: [incoming])
        #expect(snapshot.version == 2)
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(preview.websiteIcons == [original])
        let receipt = try f.server.importContentSnapshot(snapshot, preview: preview)
        #expect(receipt.websiteIcons == [original])
        #expect(receipt.websiteIconCursor == 1)
        #expect(try f.server.importContentSnapshot(snapshot, preview: preview) == receipt)
        let v1 = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: f.binding, sourceDeviceID: UUID(),
            captures: [capture])
        #expect(v1.version == 1)
        let v1Preview = try f.server.previewContentSnapshotImport(v1)
        #expect(v1Preview.websiteIcons == nil)
        _ = try f.server.importContentSnapshot(v1, preview: v1Preview)
        #expect(try f.server.websiteIconBaseline().records == [original])
        #expect(
            try SyncDatabase.decode(ContentSnapshotImport.self, SyncDatabase.encode(snapshot))
                == snapshot)
    }

    @Test func snapshotMissingAssetIsAtomicAndSeedEnlistsVerifiedCompleteBaseline() throws {
        let f = try IconFixture()
        defer { f.clean() }
        let capture = f.capture()
        let blob = BlobReference(data: iconPNG)
        let icon = WebsiteIconRecord(
            origin: f.origin, revision: 0, content: WebsiteIconContent(blob: blob))
        let snapshot = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: f.binding, sourceDeviceID: UUID(),
            captures: [capture], websiteIcons: [icon])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(throws: SyncError.blobMissing) {
            try f.server.importContentSnapshot(snapshot, preview: preview)
        }
        #expect(try f.server.baseline().captures.isEmpty)
        #expect(try f.server.baseline().cursor == 0)
        #expect(try f.server.websiteIconBaseline().records.isEmpty)
        _ = try f.server.blobs.put(iconPNG)
        _ = try f.server.importContentSnapshot(snapshot, preview: preview)
        let baseline = try f.server.websiteIconBaseline()
        let a = try f.client("a", device: f.a)
        try a.pull(from: f.transport(f.a))
        _ = try a.blobs.put(iconPNG)
        #expect(throws: SyncTransactionError.requiresTransaction) {
            try a.writer.writeWithoutTransaction {
                try SyncClient.seedWebsiteIconBaseline(
                    in: $0, baseline: baseline, binding: f.binding, deviceID: f.a, blobs: a.blobs)
            }
        }
        try a.writer.write {
            try SyncClient.seedWebsiteIconBaseline(
                in: $0, baseline: baseline, binding: f.binding, deviceID: f.a, blobs: a.blobs)
        }
        #expect(try a.websiteIconCursor() == baseline.cursor)
        #expect(try a.websiteIcons() == baseline.records)
        #expect(throws: SyncError.invalidOperation) {
            try a.writer.write {
                try SyncClient.seedWebsiteIconBaseline(
                    in: $0, baseline: baseline, binding: f.binding, deviceID: f.a, blobs: a.blobs)
            }
        }
        #expect(try a.pendingOperations().isEmpty)
    }

    @Test func poisonedUploadNeverPublishesAndSequenceRemainsUsable() throws {
        let f = try IconFixture()
        defer { f.clean() }
        var bytes = iconPNG
        bytes[40] ^= 1
        let poisoned = BlobReference(data: bytes)
        #expect(throws: SyncError.invalidBlob) {
            try f.transport(f.a).uploadWebsiteIcon(poisoned, offset: 0, chunk: bytes, final: true)
        }
        #expect(throws: SyncError.blobMissing) { try f.server.blobs.read(poisoned) }
        #expect(
            !FileManager.default.fileExists(
                atPath: f.server.blobs.directory.appendingPathComponent(
                    poisoned.digest + ".partial"
                ).path))
        let valid = BlobReference(data: iconPNG)
        try f.transport(f.a).uploadWebsiteIcon(
            valid, offset: 0, chunk: iconPNG.prefix(60), final: false)
        try f.transport(f.a).uploadWebsiteIcon(valid, offset: 0, chunk: iconPNG, final: true)
        #expect(try f.server.blobs.read(valid) == iconPNG)
        let op = WebsiteIconOperation(
            deviceID: f.a, sequence: 1, origin: f.origin, baseRevision: 0, mutation: .tombstone)
        #expect(try f.transport(f.a).applyWebsiteIcon(op).outcome == .accepted)
        #expect(try f.server.baseline().cursor == 0)
    }

    @Test func automaticTombstoneFailureRollsCaptureAndIconHistoryBackTogether() throws {
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        let capture = f.capture()
        try a.enqueue(captureID: capture.id, mutation: .create(capture))
        try a.push(to: f.transport(f.a))
        let blob = try a.blobs.put(iconPNG)
        try a.enqueueWebsiteIcon(
            origin: f.origin, mutation: .upsert(WebsiteIconContent(blob: blob)))
        try a.pushWebsiteIcons(to: f.transport(f.a))
        let captureBaseline = try f.server.baseline()
        let iconBaseline = try f.server.websiteIconBaseline()
        try f.server.writer.write {
            try $0.execute(
                sql:
                    "CREATE TRIGGER reject_icon_tombstone BEFORE INSERT ON sync_website_icon_feed WHEN NEW.cursor=2 BEGIN SELECT RAISE(ABORT,'synthetic rollback'); END"
            )
        }
        let operation = try a.enqueue(captureID: capture.id, mutation: .delete)
        #expect(throws: SyncHTTPError.unavailable) { try a.push(to: f.transport(f.a)) }
        #expect(try f.server.baseline() == captureBaseline)
        #expect(try f.server.websiteIconBaseline() == iconBaseline)
        #expect(try a.pendingOperations() == [operation])
        try f.server.writer.write { try $0.execute(sql: "DROP TRIGGER reject_icon_tombstone") }
        try a.push(to: f.transport(f.a))
        #expect(try f.server.baseline().deviceSequences[f.a] == 2)
        #expect(try f.server.websiteIconBaseline().records.first?.deleted == true)
    }

    @Test func ownSequenceCollisionAndForgedPrincipalPreservePendingState() throws {
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        let blob = try a.blobs.put(iconPNG)
        let operation = try a.enqueueWebsiteIcon(
            origin: f.origin, mutation: .upsert(WebsiteIconContent(blob: blob)))
        let record = WebsiteIconRecord(
            origin: f.origin, revision: 1, content: WebsiteIconContent(blob: blob))
        let change = WebsiteIconFeedChange(
            cursor: 1, record: record, operationID: UUID(), deviceID: f.a,
            sequence: operation.sequence)
        #expect(throws: SyncError.recoverySequenceCollision) {
            try a.validateWebsiteIconPage(
                WebsiteIconFeedPage(cursor: 1, changes: [change]), cursor: 0)
        }
        let forged = SyncHTTPTransport(
            binding: f.binding, deviceID: f.a, credential: { f.a.uuidString },
            execute: { request in
                let response = f.handler(f.a).handle(request)
                let reply = try SyncDatabase.decode(SyncHTTPReply.self, response.body)
                let bad = SyncPrincipal(
                    serviceID: f.binding.serviceID, libraryID: UUID(), deviceID: f.a)
                return SyncHTTPResponse(
                    status: response.status, headers: response.headers,
                    body: try SyncDatabase.encode(
                        SyncHTTPReply(
                            version: 1, principal: bad, result: reply.result,
                            metadataContractVersion: 1, websiteIconContractVersion: 1)))
            })
        #expect(throws: SyncHTTPError.invalidResponse) { try a.pushWebsiteIcons(to: forged) }
        #expect(try a.pendingWebsiteIconOperations() == [operation])
        #expect(try a.websiteIconCursor() == 0)
        #expect(try f.server.websiteIconBaseline().deviceSequences.isEmpty)
    }

    @Test func unboundIconStatePreventsEnrollmentButPristineNamespaceDoesNot() throws {
        let f = try IconFixture()
        defer { f.clean() }
        let path = f.root.appendingPathComponent("unbound.sqlite")
        let assets = f.root.appendingPathComponent("unbound-assets")
        let device = UUID()
        let unbound = try SyncClient(databaseURL: path, blobDirectory: assets, deviceID: device)
        try unbound.writer.write { try WebsiteIconDatabase.prepare($0) }
        let enrolled = try SyncClient(
            databaseURL: path, blobDirectory: assets, deviceID: device, binding: f.binding)
        #expect(enrolled.binding == f.binding)
        let other = f.root.appendingPathComponent("nonempty.sqlite")
        let otherAssets = f.root.appendingPathComponent("nonempty-assets")
        let used = try SyncClient(databaseURL: other, blobDirectory: otherAssets, deviceID: device)
        try used.writer.write { db in
            try WebsiteIconDatabase.prepare(db)
            try WebsiteIconDatabase.save(
                db, WebsiteIconRecord(origin: f.origin, revision: 1, deleted: true, content: nil))
        }
        #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
            try SyncClient(
                databaseURL: other, blobDirectory: otherAssets, deviceID: device, binding: f.binding
            )
        }
    }

    @Test func snapshotDeletionRetainsBytesAndTargetReviewBecomesStaleOnIconChange() throws {
        let f = try IconFixture()
        defer { f.clean() }
        let a = try f.client("a", device: f.a)
        let capture = f.capture()
        try a.enqueue(captureID: capture.id, mutation: .create(capture))
        try a.push(to: f.transport(f.a))
        let blob = try a.blobs.put(iconPNG)
        try a.enqueueWebsiteIcon(
            origin: f.origin, mutation: .upsert(WebsiteIconContent(blob: blob)))
        try a.pushWebsiteIcons(to: f.transport(f.a))
        var deleted = capture
        deleted.deleted = true
        let snapshot = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: f.binding, sourceDeviceID: f.b, captures: [deleted],
            websiteIcons: [])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(preview.websiteIcons?.first?.deleted == true)
        try a.enqueueWebsiteIcon(
            origin: f.origin,
            mutation: .upsert(
                WebsiteIconContent(blob: blob, fetchedAt: Date(timeIntervalSince1970: 7))))
        try a.pushWebsiteIcons(to: f.transport(f.a))
        #expect(throws: ContentSnapshotImportError.stalePreview) {
            try f.server.importContentSnapshot(snapshot, preview: preview)
        }
        let fresh = try f.server.previewContentSnapshotImport(snapshot)
        let receipt = try f.server.importContentSnapshot(snapshot, preview: fresh)
        #expect(receipt.websiteIcons == fresh.websiteIcons)
        #expect(receipt.websiteIconCursor == 3)
        #expect(try f.server.blobs.read(blob) == iconPNG)
        #expect(try f.server.websiteIconBaseline().records.first?.deleted == true)
    }

}

private let iconPNG = Data(
    base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAqElEQVR4nOXOIQEAAAwEoetf+hcDMYGnas/xgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9QB1h88OKlPjZIAAAAAElFTkSuQmCC"
)!

private struct IconFixture: Sendable {
    let root: URL
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let a = UUID()
    let b = UUID()
    let server: SyncServer
    let origin = WebsiteIconOrigin(url: "https://www.capd.dev")!
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-icon-test-\(UUID())")
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-assets"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
    }
    func client(_ name: String, device: UUID) throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("\(name).sqlite"),
            blobDirectory: root.appendingPathComponent("\(name)-assets"), deviceID: device,
            binding: binding)
    }
    func capture(path: String = "/first") -> SharedCapture {
        SharedCapture(
            source: CaptureSource(
                kind: .link, contentHash: origin.canonicalHTTPSOrigin + path,
                url: origin.canonicalHTTPSOrigin + path))
    }
    func handler(_ device: UUID) -> SyncHTTPHandler {
        SyncHTTPHandler(
            serviceID: binding.serviceID,
            authorizer: IconAuthorizer(
                principal: SyncPrincipal(
                    serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: device)),
            server: { _ in server })
    }
    func transport(_ device: UUID) -> SyncHTTPTransport {
        SyncHTTPTransport(
            binding: binding, deviceID: device, credential: { device.uuidString },
            execute: { handler(device).handle($0) })
    }
    func asyncTransport(_ device: UUID) -> IconAsyncTransport {
        IconAsyncTransport(binding: binding, deviceID: device, handler: handler(device))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
private struct IconAuthorizer: SyncAuthorizer {
    let principal: SyncPrincipal
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        bearerCredential == principal.deviceID.uuidString ? principal : nil
    }
}
private struct IconAsyncTransport: AsyncSyncTransport {
    let binding: SyncLibraryBinding
    let deviceID: UUID
    let handler: SyncHTTPHandler
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        handler.handle(request)
    }
}

private final class IconCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private struct IconClosureAsyncTransport: AsyncSyncTransport {
    let binding: SyncLibraryBinding
    let deviceID: UUID
    let execute: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse { try execute(request) }
}
