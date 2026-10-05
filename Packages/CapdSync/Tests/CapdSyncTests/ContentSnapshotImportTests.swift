import Foundation
import GRDB
import Testing

@testable import CapdSync

@Suite("Explicit content snapshot imports")
struct ContentSnapshotImportTests {
    @Test func newDeviceAdmissionCannotStrandImportedRecord() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let cursor: Int64 = 1_000_000_000_000_000_000
        try f.seedMetadata(cursor: cursor, sequence: 1)
        try f.database.write { db in
            for _ in 0..<3 {
                try db.execute(
                    sql: "INSERT INTO sync_devices (id, sequence) VALUES (?, ?)",
                    arguments: [UUID().uuidString, Int64.max])
            }
        }
        var capture = f.capture(id: f.duplicateID, hash: "enrollment-limit", note: "Existing note")
        capture.revision = cursor + 1
        capture.noteRevision = cursor + 1
        capture.seenCount = Int.max
        capture.manualTags = [""]
        capture.manualTags[0] = String(
            repeating: "x",
            count: try f.responseBudget().maximumCaptureBytes - SyncDatabase.encode(capture).count)
        let snapshot = f.snapshot([capture])
        try f.server.importContentSnapshot(
            snapshot, preview: f.server.previewContentSnapshotImport(snapshot))
        #expect(try f.transport(f.seedDevice).baseline().captures.count == 1)
        let asset = try f.server.blobs.put(Data("unchanged enrollment asset".utf8))
        var accepted = 0
        var rejected: SyncOperation?
        for _ in 0..<8 {
            let device = UUID()
            let operation = SyncOperation(
                deviceID: device, sequence: 1, captureID: UUID(), baseRevision: 0,
                mutation: .delete)
            let before = try f.logicalState()
            do {
                let receipt = try f.transport(device).apply(operation)
                #expect(receipt.outcome == .missing)
                accepted += 1
            } catch SyncHTTPError.resourceLimit {
                rejected = operation
                let unchanged = try f.logicalState() == before
                #expect(unchanged)
                break
            }
        }
        let baseline = try f.server.baseline()
        let actualReplyBytes = try f.baselineReplyBytes(
            baseline.captures[0], cursor: baseline.cursor, sequences: baseline.deviceSequences)
        print(
            "New-device admission: accepted \(accepted), baseline reply bytes \(actualReplyBytes)")
        var recoveryFailed = false
        do { _ = try f.transport(f.seedDevice).baseline() } catch SyncHTTPError.resourceLimit {
            recoveryFailed = true
        }
        #expect(rejected != nil)
        #expect(!recoveryFailed)
        #expect(try f.server.blobs.read(asset) == Data("unchanged enrollment asset".utf8))
        if let rejected {
            let current = baseline.captures[0]
            try f.transport(f.seedDevice).apply(
                SyncOperation(
                    deviceID: f.seedDevice, sequence: 2, captureID: current.id,
                    baseRevision: current.revision,
                    mutation: .edit(CaptureEdit(removeTags: current.manualTags))))
            #expect(try f.transport(rejected.deviceID).apply(rejected).outcome == .missing)
            #expect(try f.transport(rejected.deviceID).baseline().captures.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func growingMutationCannotExceedBaselineBudget(editExisting: Bool) throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        try f.seedMetadata(cursor: 9, sequence: 9)
        try f.database.write { db in
            for _ in 0..<49 {
                try db.execute(
                    sql: "INSERT INTO sync_devices (id, sequence) VALUES (?, ?)",
                    arguments: [UUID().uuidString, Int64.max])
            }
        }
        let operationID = UUID()
        var incoming = f.capture(id: f.duplicateID, hash: "mutation-limit")
        if editExisting {
            incoming.revision = 9
            try f.database.write { try SyncDatabase.save($0, incoming) }
        }
        var candidate = incoming
        candidate.revision = 10
        if !editExisting { candidate.noteOperationID = operationID }
        candidate.manualTags = [""]
        func feedBytes(_ capture: SharedCapture) throws -> Int {
            let change = FeedChange(
                cursor: 10, operationID: operationID, deviceID: f.seedDevice, sequence: 10,
                requestedCaptureID: capture.id, capture: capture)
            return try f.replyBytes(.page(FeedPage(cursor: 10, changes: [change])))
        }
        candidate.manualTags[0] = String(
            repeating: "x", count: SyncHTTPHandler.maximumBodyBytes - (try feedBytes(candidate)))
        incoming.manualTags = candidate.manualTags
        let operation = SyncOperation(
            id: operationID, deviceID: f.seedDevice, sequence: 10, captureID: incoming.id,
            baseRevision: editExisting ? 9 : 0,
            mutation: editExisting
                ? .edit(CaptureEdit(addTags: candidate.manualTags)) : .create(incoming))
        #expect(try feedBytes(candidate) == SyncHTTPHandler.maximumBodyBytes)
        #expect(
            try f.replyBytes(
                .receipt(
                    SyncReceipt(operationID: operationID, outcome: .accepted, capture: candidate)))
                < SyncHTTPHandler.maximumBodyBytes)
        let sequences = try f.server.baseline().deviceSequences.merging([f.seedDevice: 10]) {
            _, new in new
        }
        let prospectiveBaselineBytes = try f.baselineReplyBytes(
            candidate, cursor: 10, sequences: sequences)
        #expect(prospectiveBaselineBytes > SyncHTTPHandler.maximumBodyBytes)
        let request = SyncHTTPEnvelope(
            expectedServiceID: f.binding.serviceID, expectedLibraryID: f.binding.libraryID,
            expectedDeviceID: f.seedDevice, action: .apply(operation))
        #expect(try SyncDatabase.encode(request).count <= SyncHTTPHandler.maximumBodyBytes)
        let before = try f.logicalState()
        var rejected = false
        do { _ = try f.transport(f.seedDevice).apply(operation) } catch SyncHTTPError.resourceLimit
        { rejected = true }
        let unchanged = try f.logicalState() == before
        var recoveryFailed = false
        do { _ = try f.transport(f.seedDevice).baseline() } catch SyncHTTPError.resourceLimit {
            recoveryFailed = true
        }
        print(
            "Growing mutation: edit \(editExisting), prospective baseline bytes \(prospectiveBaselineBytes)"
        )
        #expect(rejected)
        #expect(unchanged)
        #expect(!recoveryFailed)
    }

    @Test func mutationConsumesOnlyRemainingScalarHeadroom() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let cursor: Int64 = 1_000_000_000_000_000_000
        try f.seedMetadata(cursor: cursor, sequence: 9)
        try f.database.write { db in
            for _ in 0..<49 {
                try db.execute(
                    sql: "INSERT INTO sync_devices (id, sequence) VALUES (?, ?)",
                    arguments: [UUID().uuidString, Int64.max])
            }
        }
        let budget = try SyncHTTPResponseBudget(
            principal: SyncPrincipal(
                serviceID: f.binding.serviceID, libraryID: f.binding.libraryID,
                deviceID: f.seedDevice), deviceCount: 50)
        var original = f.capture(id: f.duplicateID, hash: "remaining-headroom")
        original.revision = cursor
        original.noteRevision = cursor
        original.seenCount = Int.max
        try f.database.write { try SyncDatabase.save($0, original) }
        var candidate = original
        candidate.manualTags = [""]
        candidate.manualTags[0] = String(
            repeating: "x",
            count: budget.maximumEnvelopeCaptureBytes - (try SyncDatabase.encode(candidate).count))
        #expect(try SyncDatabase.encode(candidate).count > budget.maximumCaptureBytes)
        try budget.validateMutationCapture(candidate)
        let transport = f.transport(f.seedDevice)
        var current = original
        let mutations: [CaptureMutation] = [
            .edit(CaptureEdit(addTags: candidate.manualTags)), .delete, .restore, .recapture,
        ]
        for (offset, mutation) in mutations.enumerated() {
            let receipt = try transport.apply(
                SyncOperation(
                    deviceID: f.seedDevice, sequence: Int64(10 + offset), captureID: current.id,
                    baseRevision: current.revision, mutation: mutation))
            #expect(receipt.outcome == .accepted)
            current = try #require(receipt.capture)
            #expect(try transport.baseline().captures.first == current)
            #expect(
                try transport.changes(after: current.revision - 1, limit: 1).changes.first?.capture
                    == current)
        }
        #expect(current.seenCount == Int.max)
        #expect(try SyncDatabase.encode(current).count == budget.maximumEnvelopeCaptureBytes)
        let newDevice = UUID()
        let repaired = try f.transport(newDevice).apply(
            SyncOperation(
                deviceID: newDevice, sequence: 1, captureID: current.id,
                baseRevision: current.revision,
                mutation: .edit(CaptureEdit(removeTags: current.manualTags))))
        #expect(repaired.capture?.manualTags.isEmpty == true)
        #expect(try f.transport(newDevice).baseline().deviceSequences[newDevice] == 1)
        #expect(try transport.baseline().captures.first?.manualTags.isEmpty == true)
    }

    @Test func knownDeviceSequenceGrowthCannotStrandImportedRecord() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        try f.seedMetadata(cursor: 8, sequence: 9)
        let capture = try f.baselineLimitCapture(cursor: 9, sequence: 9)
        #expect(
            try f.baselineReplyBytes(capture, cursor: 9, sequences: [f.seedDevice: 9])
                == SyncHTTPHandler.maximumBodyBytes)
        #expect(
            try f.baselineReplyBytes(capture, cursor: 9, sequences: [f.seedDevice: 10])
                == SyncHTTPHandler.maximumBodyBytes + 1)
        let before = try f.logicalState()
        #expect(throws: SyncHTTPError.resourceLimit) {
            try f.server.previewContentSnapshotImport(f.snapshot([capture]))
        }
        #expect(try f.logicalState() == before)
    }

    @Test func importRevalidatesUntouchedRecordBeforeCursorGrowth() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        try f.seedMetadata(cursor: 9, sequence: 9)
        let capture = try f.baselineLimitCapture(cursor: 9, sequence: 9)
        try f.database.write { try SyncDatabase.save($0, capture) }
        #expect(try f.transport(f.seedDevice).baseline().captures.count == 1)
        #expect(
            try f.baselineReplyBytes(
                capture, cursor: 10, sequences: [f.seedDevice: 9], totalCaptureCount: 2)
                == SyncHTTPHandler.maximumBodyBytes + 1)
        let before = try f.logicalState()
        let incoming = f.capture(id: f.uniqueID, hash: "unrelated")
        #expect(throws: SyncHTTPError.resourceLimit) {
            try f.server.previewContentSnapshotImport(f.snapshot([incoming]))
        }
        #expect(try f.logicalState() == before)
    }

    @Test func importedRecordMustAlsoFitOrdinaryOperationReplies() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        try f.seedMetadata(cursor: 8, sequence: 9)
        let capture = try f.baselineLimitCapture(cursor: 9, sequence: 9)
        let change = FeedChange(
            cursor: 10, operationID: UUID(), deviceID: f.seedDevice, sequence: 10,
            requestedCaptureID: capture.id, capture: capture)
        #expect(
            try f.replyBytes(.page(FeedPage(cursor: 10, changes: [change])))
                > SyncHTTPHandler.maximumBodyBytes)
        let before = try f.logicalState()
        #expect(throws: SyncHTTPError.resourceLimit) {
            try f.server.previewContentSnapshotImport(f.snapshot([capture]))
        }
        #expect(try f.logicalState() == before)
    }

    @Test func oversizedTagUnionRejectsImportWithoutChangingAuthority() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        var original = f.capture(id: f.duplicateID, hash: "duplicate")
        original.manualTags = [String(repeating: "a", count: 9 * 1_048_576)]
        var incoming = f.capture(id: f.phoneDuplicateID, hash: "duplicate")
        incoming.manualTags = [String(repeating: "b", count: 9 * 1_048_576)]
        let snapshot = f.snapshot([incoming])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        try f.server.apply(f.operation(original))
        let importPreview = ContentSnapshotImportPreview(
            snapshotID: snapshot.snapshotID, digest: preview.digest,
            targetBinding: snapshot.targetBinding, sourceDeviceID: snapshot.sourceDeviceID,
            authorityCursor: 1, authorityFloor: 0, feedRowsToExpire: 1,
            countPolicy: snapshot.countPolicy,
            items: [
                ContentSnapshotItemPreview(
                    source: incoming, authority: try f.server.baseline().captures.first,
                    canonicalCaptureID: original.id, disposition: .merge,
                    differingFields: [.manualTags], proposedSeenCount: 1, countIsExact: false)
            ])
        #expect(try SyncDatabase.encode(original).count < SyncHTTPHandler.maximumBodyBytes)
        #expect(try SyncDatabase.encode(snapshot).count < SyncHTTPHandler.maximumBodyBytes)
        var merged = original
        merged.manualTags += incoming.manualTags
        #expect(try SyncDatabase.encode(merged).count > SyncHTTPHandler.maximumBodyBytes)
        let published = try f.server.blobs.put(Data("existing asset".utf8))
        let partialData = Data("pending asset".utf8)
        let partial = BlobReference(data: partialData)
        try f.server.upload(partial, offset: 0, chunk: partialData.prefix(3), final: false)
        let before = try f.logicalState()
        let blobFiles = try FileManager.default.contentsOfDirectory(
            atPath: f.server.blobs.directory.path)
        #expect(throws: SyncHTTPError.resourceLimit) {
            try f.server.previewContentSnapshotImport(snapshot)
        }
        #expect(throws: SyncHTTPError.resourceLimit) {
            try f.server.importContentSnapshot(snapshot, preview: importPreview)
        }
        #expect(try f.logicalState() == before)
        #expect(try f.tableExists("sync_content_snapshot_imports") == false)
        #expect(try f.tableExists("sync_content_snapshot_expired_feed") == false)
        #expect(try f.server.retainedContentSnapshotImport(snapshot.snapshotID) == nil)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: f.server.blobs.directory.path)
                == blobFiles)
        #expect(try f.server.blobs.read(published) == Data("existing asset".utf8))
        #expect(
            try Data(
                contentsOf: f.server.blobs.directory.appendingPathComponent(
                    partial.digest + ".partial"))
                == partialData.prefix(3))
        #expect(try f.transport(f.seedDevice).baseline().captures.count == 1)
    }

    @Test func tagMergeFitsOnlyWithinCommonResponseBudget() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        var original = f.capture(id: f.duplicateID, hash: "duplicate")
        original.manualTags = ["Authority tag"]
        let receipt = try f.server.apply(f.operation(original))
        var merged = try #require(receipt.capture)
        merged.revision += 1
        merged.manualTags.append("")
        let budget = try f.responseBudget()
        let overhead = try SyncDatabase.encode(merged).count
        var incoming = f.capture(id: f.phoneDuplicateID, hash: "duplicate")
        incoming.manualTags = [
            String(repeating: "b", count: budget.maximumCaptureBytes - overhead + 1)
        ]
        merged.manualTags[1] = incoming.manualTags[0]
        #expect(try SyncDatabase.encode(merged).count < SyncHTTPHandler.maximumBodyBytes)
        #expect(try SyncDatabase.encode(merged).count == budget.maximumCaptureBytes + 1)
        let tooLarge = f.snapshot([incoming])
        #expect(try SyncDatabase.encode(tooLarge).count < SyncHTTPHandler.maximumBodyBytes)
        let before = try f.logicalState()
        #expect(throws: SyncHTTPError.resourceLimit) {
            try f.server.previewContentSnapshotImport(tooLarge)
        }
        #expect(try f.logicalState() == before)
        incoming.manualTags[0].removeLast()
        let fits = f.snapshot([incoming])
        let preview = try f.server.previewContentSnapshotImport(fits)
        let imported = try f.server.importContentSnapshot(fits, preview: preview)
        let recovered = try f.transport(f.seedDevice).baseline()
        #expect(recovered.cursor == imported.authorityCursor)
        #expect(recovered.captures.first?.manualTags == ["Authority tag", incoming.manualTags[0]])
        #expect(try SyncDatabase.encode(recovered.captures[0]).count == budget.maximumCaptureBytes)

    }

    @Test func safeImportSupportsMetadataGrowthAndOrdinaryHTTPMutations() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        try f.seedMetadata(cursor: 8, sequence: 9)
        let otherDevices = (0..<3).map { _ in UUID() }
        try f.database.write { db in
            for device in otherDevices {
                try db.execute(
                    sql: "INSERT INTO sync_devices (id, sequence) VALUES (?, 9)",
                    arguments: [device.uuidString])
            }
        }
        let budget = try f.responseBudget()
        var capture = f.capture(id: f.duplicateID, hash: "large")
        capture.revision = 9
        capture.seenCount = 9
        capture.manualTags = [""]
        capture.manualTags[0] = String(
            repeating: "x",
            count: budget.maximumCaptureBytes - (try SyncDatabase.encode(capture).count))
        let snapshot = f.snapshot([capture])
        let imported = try f.server.importContentSnapshot(
            snapshot, preview: f.server.previewContentSnapshotImport(snapshot))
        #expect(imported.authorityCursor == 9)
        let sourceTransport = f.transport(f.sourceDevice)
        let sourceMissing = try sourceTransport.apply(
            SyncOperation(
                deviceID: f.sourceDevice, sequence: 1, captureID: UUID(), baseRevision: 0,
                mutation: .delete))
        #expect(sourceMissing.outcome == .missing)
        let transport = f.transport(f.seedDevice)
        let missing = try transport.apply(
            SyncOperation(
                deviceID: f.seedDevice, sequence: 10, captureID: UUID(), baseRevision: 0,
                mutation: .delete))
        #expect(missing.outcome == .missing)
        try f.database.write { db in
            for device in otherDevices {
                try db.execute(
                    sql: "UPDATE sync_devices SET sequence=? WHERE id=?",
                    arguments: [Int64.max, device.uuidString])
            }
        }
        var current = try #require(try transport.baseline().captures.first)
        #expect(try transport.baseline().deviceSequences[f.seedDevice] == 10)
        #expect(try transport.baseline().deviceSequences[f.sourceDevice] == 1)
        let mutations: [CaptureMutation] = [
            .edit(CaptureEdit(rating: 4)), .delete, .restore, .recapture,
        ]
        for (offset, mutation) in mutations.enumerated() {
            let previousCursor = current.revision
            let receipt = try transport.apply(
                SyncOperation(
                    deviceID: f.seedDevice, sequence: Int64(11 + offset), captureID: current.id,
                    baseRevision: current.revision, mutation: mutation))
            #expect(receipt.outcome == .accepted)
            current = try #require(receipt.capture)
            #expect(
                try transport.changes(after: previousCursor, limit: 1).changes.first?.capture
                    == current)
            #expect(try transport.baseline().captures.first == current)
        }
        #expect(current.revision == 13)
        #expect(current.seenCount == 10)
        var future = current
        future.revision = Int64.max
        future.noteRevision = Int64.max
        future.seenCount = Int.max
        future.deleted = false
        let sequences = Dictionary(
            uniqueKeysWithValues: ([f.seedDevice, f.sourceDevice] + otherDevices)
                .map { ($0, Int64.max) })
        let change = FeedChange(
            cursor: Int64.max, operationID: UUID(), deviceID: f.seedDevice, sequence: Int64.max,
            requestedCaptureID: future.id, capture: future)
        var replySizes = [
            try f.replyBytes(
                .baseline(
                    Baseline(
                        cursor: Int64.max, captures: [future], deviceSequences: sequences,
                        totalCaptureCount: Int.max)), contractVersion: Int.max),
            try f.replyBytes(
                .page(FeedPage(cursor: Int64.max, changes: [change])), contractVersion: Int.max),
        ]
        for outcome: SyncReceipt.Outcome in [
            .accepted, .noteConflict, .deleted, .staleRestore, .missing, .alreadyExists,
        ] {
            replySizes.append(
                try f.replyBytes(
                    .receipt(SyncReceipt(operationID: UUID(), outcome: outcome, capture: future)),
                    contractVersion: Int.max))
        }
        #expect(replySizes.max()! <= SyncHTTPHandler.maximumBodyBytes)
        let remove = SyncOperation(
            deviceID: f.seedDevice, sequence: 15, captureID: current.id,
            baseRevision: current.revision,
            mutation: .edit(CaptureEdit(removeTags: current.manualTags)))
        let requestBytes = try SyncDatabase.encode(
            SyncHTTPEnvelope(
                expectedServiceID: f.binding.serviceID, expectedLibraryID: f.binding.libraryID,
                expectedDeviceID: f.seedDevice, action: .apply(remove))
        ).count
        #expect(requestBytes < SyncHTTPHandler.maximumBodyBytes)
        #expect(try transport.apply(remove).capture?.manualTags.isEmpty == true)
        #expect(try transport.baseline().captures.first?.manualTags.isEmpty == true)
    }

    @Test func legacyStoredPayloadUsesCanonicalResponseSizeBeforeImport() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        try f.seedMetadata(cursor: 9, sequence: 9)
        let budget = try f.responseBudget()
        var capture = f.capture(id: f.duplicateID, hash: "legacy")
        capture.revision = 9
        capture.manualTags = [""]
        let overhead = try SyncDatabase.encode(capture).count
        capture.manualTags[0] = String(
            repeating: "/", count: (budget.maximumCaptureBytes - overhead) / 2 + 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func saveLegacy() throws {
            let data = try encoder.encode(capture)
            #expect(data.count < budget.maximumCaptureBytes)
            try f.database.write { db in
                try SyncDatabase.save(db, capture)
                try db.execute(
                    sql: "UPDATE sync_records SET payload=? WHERE id=?",
                    arguments: [data, capture.id.uuidString])
            }
        }
        try saveLegacy()
        #expect(try SyncDatabase.encode(capture).count > budget.maximumCaptureBytes)
        let snapshot = f.snapshot([f.capture(id: f.uniqueID, hash: "unrelated")])
        let before = try f.logicalState()
        #expect(throws: SyncHTTPError.resourceLimit) {
            try f.server.previewContentSnapshotImport(snapshot)
        }
        #expect(try f.logicalState() == before)
        #expect(try f.tableExists("sync_content_snapshot_imports") == false)
        #expect(try f.tableExists("sync_content_snapshot_expired_feed") == false)
        capture.manualTags[0].removeLast()
        try saveLegacy()
        try f.server.importContentSnapshot(
            snapshot, preview: f.server.previewContentSnapshotImport(snapshot))
        #expect(try f.transport(f.seedDevice).baseline().captures.count == 2)
    }

    @Test func captureNumericAndRestoreGrowthReserveMatchesEncoding() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        var capture = f.capture(id: f.duplicateID, hash: "widths")
        capture.deleted = true
        let originalBytes = try SyncDatabase.encode(capture).count
        capture.revision = Int64.max
        capture.noteRevision = Int64.max
        capture.seenCount = Int.max
        capture.deleted = false
        let growth = try SyncDatabase.encode(capture).count - originalBytes
        #expect(growth == 55)
    }

    @Test func previewPreservesConflictsAndImportsCountAsLowerBoundWithHonestNewReceipts() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        var original = f.capture(id: f.duplicateID, hash: "duplicate", note: "Mac note")
        original.metadata = CaptureMetadata(
            updatedAt: f.date, reminderAt: f.date, sourceAppBundleID: "test.mac")
        original.generated = GeneratedContent(body: "Mac body", tags: ["Mac generated"])
        original.manualTags = ["Mac tag"]
        let operation = f.operation(original)
        let oldReceipt = try f.server.apply(operation)
        try f.server.apply(
            SyncOperation(
                deviceID: f.seedDevice, sequence: 2, captureID: original.id,
                baseRevision: 1, mutation: .recapture))
        let history = try f.history()
        let feed = try f.server.changes(after: 0, limit: 100).changes
        let feedBytes = try f.feedBytes()
        var duplicate = f.capture(id: f.phoneDuplicateID, hash: "duplicate", note: "Phone note")
        duplicate.seenCount = 7
        duplicate.rating = 1
        duplicate.createdMetadata(f.date.addingTimeInterval(0.0000001))
        duplicate.generated = GeneratedContent(
            body: "Phone body", ocrText: "Phone OCR", tags: ["Phone generated"])
        duplicate.manualTags = ["Phone tag"]
        duplicate.unknownFields = [
            "futurePhone": .object(["exact": .number(Decimal(string: "9007199254740993")!)])
        ]
        var unique = f.capture(id: f.uniqueID, hash: "unique", note: "Imported original note")
        unique.seenCount = 4
        unique.metadata = duplicate.metadata
        unique.noteConflicts = [
            NoteVariant(
                operationID: UUID(), value: "Original unresolved variant",
                unknownFields: ["future": .bool(true)])
        ]
        unique.revision = 99
        unique.noteRevision = 99
        let snapshot = f.snapshot([duplicate, unique])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(try f.history() == history)
        #expect(try f.tableExists("sync_content_snapshot_imports") == false)
        let match = try #require(preview.items.first { $0.source.id == duplicate.id })
        #expect(match.authority?.metadata == original.metadata)
        #expect(match.source.metadata == duplicate.metadata)
        #expect(match.differingFields.contains(.metadata))
        #expect(match.differingFields.contains(.seenCount))
        #expect(match.differingFields.contains(.note))
        #expect(match.differingFields.contains(.generated))
        #expect(match.proposedSeenCount == 7)
        #expect(!match.countIsExact)
        #expect(preview.items.allSatisfy { !$0.countIsExact })
        #expect(preview.feedRowsToExpire == feed.count)
        let receipt = try f.server.importContentSnapshot(snapshot, preview: preview)
        #expect(receipt.id != operation.id)
        #expect(receipt.items.allSatisfy { $0.id != operation.id })
        #expect(try f.history() == history)
        #expect(try f.server.apply(operation) == oldReceipt)
        #expect(try f.server.expiredContentSnapshotFeed(snapshot.snapshotID) == feed)
        #expect(try f.feedBytes(snapshot.snapshotID) == feedBytes)
        #expect(throws: SyncError.cursorExpired) {
            try f.server.changes(after: preview.authorityCursor, limit: 100)
        }
        let imported = try #require(try f.server.baseline().captures.first { $0.id == unique.id })
        #expect(imported.seenCount == 4)
        #expect(imported.createdAt == unique.createdAt)
        #expect(imported.metadata == unique.metadata)
        #expect(imported.note == unique.note)
        #expect(imported.noteOperationID != unique.noteOperationID)
        #expect(
            imported.noteConflicts.first?.operationID != unique.noteConflicts.first?.operationID)
        #expect(
            imported.noteConflicts.first?.unknownFields == unique.noteConflicts.first?.unknownFields
        )
        #expect(imported.noteRevision == receipt.authorityCursor)
        let merged = try #require(try f.server.baseline().captures.first { $0.id == original.id })
        #expect(merged.seenCount == 7)
        #expect(merged.createdAt == original.createdAt)
        #expect(merged.metadata == original.metadata)
        #expect(merged.generated == original.generated)
        #expect(merged.rating == original.rating)
        #expect(merged.manualTags == ["Mac tag", "Phone tag"])
        #expect(Set(merged.noteConflicts.compactMap(\.value)) == ["Mac note", "Phone note"])
        let retained = try #require(try f.server.retainedContentSnapshotImport(snapshot.snapshotID))
        #expect(retained.snapshot == snapshot)
        #expect(retained.preview == preview)
        #expect(retained.receipt == receipt)
        #expect(try f.server.importContentSnapshot(snapshot, preview: preview) == receipt)
        let reopened = try f.reopenServer()
        #expect(try reopened.importContentSnapshot(snapshot, preview: preview) == receipt)
        #expect(try f.history() == history)
        let repeatedContent = f.snapshot([duplicate], snapshotID: UUID())
        try reopened.importContentSnapshot(
            repeatedContent, preview: reopened.previewContentSnapshotImport(repeatedContent))
        #expect(try reopened.baseline().captures.first { $0.id == original.id }?.seenCount == 7)
        #expect(
            try reopened.baseline().captures.first { $0.id == original.id }?.noteConflicts.count
                == 2)
        var changed = duplicate
        changed.note = "Changed snapshot bytes"
        #expect(throws: ContentSnapshotImportError.snapshotIDReused) {
            try reopened.importContentSnapshot(
                f.snapshot([changed, unique], snapshotID: snapshot.snapshotID), preview: preview)
        }
    }

    @Test func expiredFeedRecoversConnectedClientsWithoutAcknowledgingPendingOverlays() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.duplicateID, hash: "duplicate", note: "Authority note")
        let seed = f.operation(capture)
        let seedReceipt = try f.server.apply(seed)
        let a = try f.client("a")
        let b = try f.client("b")
        try a.pull(from: f.transport(a.deviceID))
        try b.pull(from: f.transport(b.deviceID))
        let note = try a.enqueue(
            captureID: capture.id,
            mutation: .edit(CaptureEdit(note: NoteEdit("Offline connected-client note"))))
        let local = f.capture(id: UUID(), hash: "unrelated-local", note: "Local new capture")
        let create = try b.enqueue(captureID: local.id, mutation: .create(local))
        let aBytes = try f.outbox("a")
        let bBytes = try f.outbox("b")
        let before = try f.history()
        let feed = try f.server.changes(after: 0, limit: 100).changes
        var phone = f.capture(
            id: f.phoneDuplicateID, hash: "duplicate", note: "Phone content snapshot note")
        phone.seenCount = 5
        phone.revision = 71
        phone.noteRevision = 71
        let snapshot = f.snapshot([phone])
        let imported = try f.server.importContentSnapshot(
            snapshot, preview: f.server.previewContentSnapshotImport(snapshot))
        #expect(try f.history() == before)
        #expect(try f.server.baseline().deviceSequences[snapshot.sourceDeviceID] == nil)
        #expect(try f.server.apply(seed) == seedReceipt)
        #expect(try f.server.expiredContentSnapshotFeed(snapshot.snapshotID) == feed)
        try a.pull(from: f.transport(a.deviceID))
        try b.pull(from: f.transport(b.deviceID))
        #expect(try a.cursor() == imported.authorityCursor)
        #expect(try b.cursor() == imported.authorityCursor)
        #expect(try a.pendingOperations() == [note])
        #expect(try b.pendingOperations() == [create])
        #expect(try f.outbox("a") == aBytes)
        #expect(try f.outbox("b") == bBytes)
        #expect(try a.captures().first?.note == "Offline connected-client note")
        #expect(try a.captures().first?.seenCount == 5)
        #expect(try b.captures().contains { $0.id == local.id && $0.note == "Local new capture" })
        let newReceipt = try #require(try a.push(to: f.transport(a.deviceID)).first)
        #expect(newReceipt.operationID == note.id)
        #expect(newReceipt.outcome == .noteConflict)
        #expect(try a.pendingOperations().isEmpty)
        #expect(try f.server.baseline().deviceSequences[a.deviceID] == 1)
        try b.push(to: f.transport(b.deviceID))
        #expect(try b.pendingOperations().isEmpty)
        #expect(try f.server.baseline().deviceSequences[b.deviceID] == 1)
    }

    @Test func stalePreviewAndIdentityCollisionNeverChangeAuthority() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.duplicateID, hash: "duplicate", note: "Original")
        try f.server.apply(f.operation(capture))
        let snapshot = f.snapshot([f.capture(id: f.uniqueID, hash: "new")])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        try f.server.apply(
            SyncOperation(
                deviceID: f.seedDevice, sequence: 2, captureID: capture.id,
                baseRevision: 1,
                mutation: .edit(CaptureEdit(note: NoteEdit("Changed after preview")))))
        let baseline = try f.server.baseline()
        let history = try f.history()
        #expect(throws: ContentSnapshotImportError.stalePreview) {
            try f.server.importContentSnapshot(snapshot, preview: preview)
        }
        #expect(try f.server.baseline().captures == baseline.captures)
        #expect(try f.history() == history)
        #expect(try f.tableExists("sync_content_snapshot_imports") == false)
        let collision = f.snapshot([f.capture(id: capture.id, hash: "different")])
        #expect(throws: ContentSnapshotImportError.identityCollision) {
            try f.server.previewContentSnapshotImport(collision)
        }
        let currentPreview = try f.server.previewContentSnapshotImport(snapshot)
        try f.server.expireFeed(through: baseline.cursor)
        #expect(throws: ContentSnapshotImportError.stalePreview) {
            try f.server.importContentSnapshot(snapshot, preview: currentPreview)
        }
    }

    @Test func sqlFailureRollsBackAllRowsAliasesLedgerAndFeedExpiration() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.duplicateID, hash: "duplicate", note: "Keep original")
        try f.server.apply(f.operation(capture))
        var duplicate = f.capture(
            id: f.phoneDuplicateID, hash: "duplicate", note: "Imported conflict")
        duplicate.seenCount = 8
        let unique = f.capture(id: f.uniqueID, hash: "trigger-failure")
        let snapshot = f.snapshot([duplicate, unique])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        let before = try f.logicalState()
        try f.database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER fail_snapshot_insert BEFORE INSERT ON sync_records
                    WHEN NEW.id = '\(unique.id.uuidString)'
                    BEGIN SELECT RAISE(ABORT, 'synthetic import failure'); END;
                    """)
        }
        #expect(throws: (any Error).self) {
            try f.server.importContentSnapshot(snapshot, preview: preview)
        }
        #expect(try f.logicalState() == before)
        #expect(try f.tableExists("sync_content_snapshot_imports") == false)
        #expect(try f.tableExists("sync_content_snapshot_expired_feed") == false)
        try f.database.write { try $0.execute(sql: "DROP TRIGGER fail_snapshot_insert") }
        try f.server.importContentSnapshot(snapshot, preview: preview)
        #expect(try f.server.baseline().captures.count == 2)
    }

    @Test func tombstonesAndRepeatedSnapshotContentNeverBecomeRecaptures() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.duplicateID, hash: "deleted", note: "Deleted authority note")
        try f.server.apply(f.operation(capture))
        try f.server.apply(
            SyncOperation(
                deviceID: f.seedDevice, sequence: 2, captureID: capture.id, baseRevision: 1,
                mutation: .delete))
        var phone = f.capture(id: f.phoneDuplicateID, hash: "deleted", note: "Live phone original")
        phone.seenCount = 12
        let snapshot = f.snapshot([phone])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(preview.items.first?.disposition == .preserveTombstone)
        #expect(preview.items.first?.differingFields.contains(.deleted) == true)
        #expect(preview.items.first?.proposedSeenCount == 1)
        try f.server.importContentSnapshot(snapshot, preview: preview)
        let result = try #require(try f.server.baseline().captures.first)
        #expect(result.deleted)
        #expect(result.seenCount == 1)
        #expect(result.note == capture.note)
        #expect(
            try f.server.retainedContentSnapshotImport(snapshot.snapshotID)?.snapshot.captures.first
                == phone)
        var deadUnique = f.capture(id: f.uniqueID, hash: "phone-tombstone")
        deadUnique.deleted = true
        deadUnique.seenCount = 3
        let deadSnapshot = f.snapshot([deadUnique], snapshotID: UUID())
        try f.server.importContentSnapshot(
            deadSnapshot, preview: f.server.previewContentSnapshotImport(deadSnapshot))
        #expect(try f.server.baseline().captures.first { $0.id == deadUnique.id }?.deleted == true)
        #expect(try f.server.baseline().captures.first { $0.id == deadUnique.id }?.seenCount == 3)
    }

    @Test func duplicateRowsWithinSnapshotUseMaximumAndRetainBothOriginals() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        var first = f.capture(
            id: f.phoneDuplicateID, hash: "same-phone-content", note: "Phone first note")
        first.seenCount = 4
        var second = f.capture(
            id: f.uniqueID, hash: "same-phone-content", note: "Phone second note")
        second.seenCount = 9
        second.metadata = CaptureMetadata(sourceAppBundleID: "test.second")
        let snapshot = f.snapshot([second, first])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(preview.items.map(\.proposedSeenCount) == [4, 9])
        try f.server.importContentSnapshot(snapshot, preview: preview)
        let records = try f.server.baseline().captures
        #expect(records.count == 1)
        #expect(records.first?.seenCount == 9)
        #expect(
            Set(records.first!.noteConflicts.compactMap(\.value)) == [
                "Phone first note", "Phone second note",
            ])
        #expect(
            try f.server.retainedContentSnapshotImport(snapshot.snapshotID)?.snapshot == snapshot)
    }

    @Test func malformedTaggingStateFailsWithoutImportingButValidStateSurvives() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.uniqueID, hash: "processing")
        for generated in [
            GeneratedContent(taggingProcessed: true),
            GeneratedContent(taggingInputFingerprint: "input"),
            GeneratedContent(taggingProcessed: false, taggingInputFingerprint: "input"),
        ] {
            var malformed = capture
            malformed.generated = generated
            #expect(throws: SyncError.invalidOperation) {
                try f.server.previewContentSnapshotImport(f.snapshot([malformed]))
            }
            #expect(try f.server.baseline().captures.isEmpty)
        }
        var valid = capture
        valid.generated = GeneratedContent(taggingProcessed: true, taggingInputFingerprint: "input")
        let snapshot = f.snapshot([valid])
        try f.server.importContentSnapshot(
            snapshot, preview: f.server.previewContentSnapshotImport(snapshot))
        #expect(try f.server.baseline().captures.first?.generated == valid.generated)
    }

    @Test func malformedBindingInvalidCountsAndMissingAssetsFailBeforeImport() throws {
        let f = try SnapshotFixture()
        defer { f.clean() }
        let capture = f.capture(id: f.uniqueID, hash: "unique")
        #expect(throws: SyncBindingError.mismatch) {
            try f.server.previewContentSnapshotImport(
                ContentSnapshotImport(
                    snapshotID: UUID(),
                    targetBinding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()),
                    sourceDeviceID: UUID(), captures: [capture]))
        }
        #expect(throws: ContentSnapshotImportError.invalidSnapshot) {
            try f.server.previewContentSnapshotImport(f.snapshot([]))
        }
        #expect(throws: ContentSnapshotImportError.invalidSnapshot) {
            try f.server.previewContentSnapshotImport(f.snapshot([capture, capture]))
        }
        var invalid = capture
        invalid.seenCount = 0
        #expect(throws: ContentSnapshotImportError.invalidSnapshot) {
            try f.server.previewContentSnapshotImport(f.snapshot([invalid]))
        }
        let bytes = Data("Synthetic imported image".utf8)
        let blob = BlobReference(data: bytes)
        let image = SharedCapture(
            source: CaptureSource(kind: .image, contentHash: blob.digest, blob: blob),
            createdAt: f.date)
        let snapshot = f.snapshot([capture, image])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(throws: SyncError.blobMissing) {
            try f.server.importContentSnapshot(snapshot, preview: preview)
        }
        #expect(try f.server.baseline().captures.isEmpty)
        #expect(try f.tableExists("sync_content_snapshot_imports") == false)
        try f.server.upload(blob, offset: 0, chunk: bytes, final: true)
        try f.server.importContentSnapshot(snapshot, preview: preview)
        #expect(try f.server.download(blob) == bytes)
    }
}

extension SharedCapture {
    fileprivate mutating func createdMetadata(_ date: Date) {
        metadata = CaptureMetadata(
            updatedAt: date, lastSeenAt: date.addingTimeInterval(1),
            reminderAt: date.addingTimeInterval(2),
            sourceAppBundleID: "test.phone", unknownFields: ["futureMetadata": .string("retained")])
    }
}

private struct SnapshotAuthorizer: SyncAuthorizer {
    let binding: SyncLibraryBinding
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        guard let device = UUID(uuidString: bearerCredential) else { return nil }
        return SyncPrincipal(
            serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: device)
    }
}

private struct SnapshotFixture {
    let root: URL
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let seedDevice = UUID()
    let sourceDevice = UUID()
    let duplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let phoneDuplicateID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let uniqueID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
    let date = Date(timeIntervalSinceReferenceDate: 123_456_789.12345679)
    let server: SyncServer
    let database: DatabaseQueue
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-content-snapshot-\(UUID())")
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        database = try DatabaseQueue(path: root.appendingPathComponent("authority.sqlite").path)
    }
    func capture(id: UUID, hash: String, note: String? = nil) -> SharedCapture {
        SharedCapture(
            id: id,
            source: CaptureSource(
                kind: .text, contentHash: hash, title: "Original \(hash)",
                selection: "Original \(hash)"),
            createdAt: date, note: note)
    }
    func operation(_ capture: SharedCapture) -> SyncOperation {
        SyncOperation(
            deviceID: seedDevice, sequence: 1, captureID: capture.id, baseRevision: 0,
            mutation: .create(capture))
    }
    func snapshot(_ captures: [SharedCapture], snapshotID: UUID = UUID()) -> ContentSnapshotImport {
        ContentSnapshotImport(
            snapshotID: snapshotID, targetBinding: binding, sourceDeviceID: sourceDevice,
            captures: captures)
    }
    func client(_ name: String) throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("\(name).sqlite"),
            blobDirectory: root.appendingPathComponent("\(name)-blobs"), binding: binding)
    }
    func transport(_ device: UUID) -> SyncHTTPTransport {
        let handler = SyncHTTPHandler(
            serviceID: binding.serviceID, authorizer: SnapshotAuthorizer(binding: binding),
            server: { _ in server })
        return SyncHTTPTransport(
            binding: binding, deviceID: device, credential: { device.uuidString },
            execute: { handler.handle($0) })
    }
    func reopenServer() throws -> SyncServer {
        try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
    }
    func tableExists(_ name: String) throws -> Bool {
        try database.read { try $0.tableExists(name) }
    }
    func history() throws -> [String: [Row]] {
        try database.read { db in
            [
                "receipts": try Row.fetchAll(db, sql: "SELECT * FROM sync_receipts ORDER BY id"),
                "devices": try Row.fetchAll(db, sql: "SELECT * FROM sync_devices ORDER BY id"),
            ]
        }
    }
    func logicalState() throws -> [String: [Row]] {
        try database.read { db in
            try Dictionary(
                uniqueKeysWithValues: [
                    "sync_records", "sync_aliases", "sync_meta", "sync_feed", "sync_receipts",
                    "sync_devices",
                ].map {
                    ($0, try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY 1"))
                })
        }
    }
    func feedBytes(_ snapshotID: UUID? = nil) throws -> [Data] {
        try database.read { db in
            if let snapshotID {
                return try Data.fetchAll(
                    db,
                    sql:
                        "SELECT payload FROM sync_content_snapshot_expired_feed WHERE import_id=? ORDER BY cursor",
                    arguments: [snapshotID.uuidString])
            }
            return try Data.fetchAll(db, sql: "SELECT payload FROM sync_feed ORDER BY cursor")
        }
    }

    func baselineReplyBytes(
        _ capture: SharedCapture, cursor: Int64, sequences: [UUID: Int64],
        totalCaptureCount: Int = 1
    ) throws -> Int {
        try replyBytes(
            .baseline(
                Baseline(
                    cursor: cursor, captures: [capture], deviceSequences: sequences,
                    totalCaptureCount: totalCaptureCount)))
    }

    func replyBytes(_ result: SyncHTTPResult, contractVersion: Int = 1) throws -> Int {
        try SyncDatabase.encode(
            SyncHTTPResponseBudget.replyPayload(
                result,
                principal: SyncPrincipal(
                    serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: seedDevice
                ),
                contractVersion: contractVersion)
        ).count
    }

    func responseBudget() throws -> SyncHTTPResponseBudget {
        let count = try database.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_devices")!
            let sourceIsKnown = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM sync_devices WHERE id=?)",
                arguments: [sourceDevice.uuidString])!
            return count + (sourceIsKnown ? 0 : 1)
        }
        return try SyncHTTPResponseBudget(
            principal: SyncPrincipal(
                serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: sourceDevice),
            deviceCount: count)
    }

    func seedMetadata(cursor: Int64, sequence: Int64) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE sync_meta SET cursor=?", arguments: [cursor])
            try db.execute(
                sql: "INSERT INTO sync_devices (id, sequence) VALUES (?, ?)",
                arguments: [seedDevice.uuidString, sequence])
        }
    }

    func baselineLimitCapture(cursor: Int64, sequence: Int64) throws -> SharedCapture {
        var capture = capture(id: duplicateID, hash: "large")
        capture.revision = cursor
        capture.manualTags = [""]
        let overhead = try baselineReplyBytes(
            capture, cursor: cursor, sequences: [seedDevice: sequence])
        capture.manualTags = [
            String(repeating: "x", count: SyncHTTPHandler.maximumBodyBytes - overhead)
        ]
        return capture
    }

    func outbox(_ name: String) throws -> [Data] {
        let db = try DatabaseQueue(path: root.appendingPathComponent("\(name).sqlite").path)
        return try db.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
