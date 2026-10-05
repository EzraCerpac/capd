import Foundation
import GRDB
import Testing

@testable import CapdSync

struct ClientResponseValidationTests {
    @Test(arguments: ["recapture", "edit", "delete", "restore", "duplicate"])
    func definiteNextReceiptMustMatchCompleteMutation(mutation: String) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("complete transition")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        if mutation == "restore" {
            try f.client.enqueue(captureID: original.id, mutation: .delete)
            try f.client.push(to: f.server)
        }
        let operation: SyncOperation
        switch mutation {
        case "edit":
            operation = try f.client.enqueue(
                captureID: original.id, mutation: .edit(CaptureEdit(rating: 5)))
        case "delete": operation = try f.client.enqueue(captureID: original.id, mutation: .delete)
        case "restore": operation = try f.client.enqueue(captureID: original.id, mutation: .restore)
        case "duplicate":
            let duplicate = SharedCapture(source: original.source)
            operation = try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        default: operation = try f.client.enqueue(captureID: original.id, mutation: .recapture)
        }
        let before = try f.client.captures(includeDeleted: true)
        let legitimate = try f.server.apply(operation)
        var changed = try #require(legitimate.capture)
        if mutation == "edit" {
            changed.seenCount += 1
        } else {
            changed.generated.body = "Unrequested"
        }
        let forged = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: changed)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures(includeDeleted: true) == before)
        #expect(try f.client.push(to: f.server) == [legitimate])
    }

    @Test(arguments: ["rating", "tags", "note", "generated", "metadata"])
    func observedSameRevisionRetryMustEqualFeedRecord(field: String) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("observed equality")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let operation = try f.client.enqueue(captureID: original.id, mutation: .recapture)
        let legitimate = try f.server.apply(operation)
        try f.client.pull(from: f.server)
        let before = try f.client.captures()
        var changed = try #require(legitimate.capture)
        switch field {
        case "rating": changed.rating = 5
        case "tags": changed.manualTags = ["Unrequested"]
        case "note": changed.note = "Unrequested"
        case "generated": changed.generated.body = "Unrequested"
        default: changed.metadata = CaptureMetadata(sourceAppBundleID: "unrequested")
        }
        let forged = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: changed)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == before)
        #expect(try f.client.push(to: f.server) == [legitimate])
    }

    @Test(
        arguments: [
            "count", "rating", "noteRevision", "negativeNoteRevision", "image", "blob", "generated",
        ], [false, true])
    func invalidInboundCaptureIsRejectedBeforeCaching(field: String, baseline: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let blob = try f.server.blobs.put(Data("invariant asset".utf8))
        var invalid = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        invalid.revision = 1
        switch field {
        case "count": invalid.seenCount = 0
        case "rating": invalid.rating = 6
        case "noteRevision": invalid.noteRevision = 2
        case "negativeNoteRevision": invalid.noteRevision = -1
        case "image": invalid.source.blob = nil
        case "blob": invalid.source.blob = BlobReference(digest: "invalid", byteCount: 1)
        default: invalid.generated.bodyIsThin = true
        }
        let probe = DownloadProbe()
        let page = FeedPage(
            cursor: 1,
            changes: [
                FeedChange(
                    cursor: 1, operationID: UUID(), deviceID: UUID(), sequence: 1,
                    requestedCaptureID: invalid.id, capture: invalid)
            ])
        let transport = ResponseTransport(
            server: f.server,
            snapshot: baseline
                ? Baseline(cursor: 1, captures: [invalid], deviceSequences: [:]) : nil,
            page: baseline ? nil : page, onDownload: { probe.record() })
        let expectedError: SyncError = field == "blob" ? .invalidBlob : .invalidOperation
        #expect(throws: expectedError) { try f.client.pull(from: transport) }
        #expect(try f.client.cursor() == 0)
        #expect(try f.client.captures(includeDeleted: true).isEmpty)
        #expect(probe.count == 0)
        #expect(
            !FileManager.default.fileExists(
                atPath: f.client.blobs.directory.appendingPathComponent(blob.digest).path))
    }

    @Test(
        arguments: ["createdAt", "kind", "hash", "url", "host", "blob", "title", "selection"],
        [false, true])
    func remoteReplacementPreservesKnownIdentity(field: String, baseline: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        var original = f.capture("remote identity")
        original.source.title = "Known title"
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        let before = try f.client.captures()
        let current = try #require(before.first)
        let blob = try f.server.blobs.put(Data("substituted asset".utf8))
        var source = current.source
        switch field {
        case "kind":
            source.kind = .image
            source.blob = blob
        case "hash": source.contentHash = "Unrelated"
        case "url": source.url = "https://unrelated.invalid"
        case "host": source.host = "unrelated.invalid"
        case "blob": source.blob = blob
        case "title": source.title = nil
        case "selection": source.selection = nil
        default: break
        }
        var substituted = SharedCapture(
            id: current.id, source: source,
            createdAt: current.createdAt.addingTimeInterval(field == "createdAt" ? 1 : 0))
        substituted.revision = 2
        let probe = DownloadProbe()
        let page = FeedPage(
            cursor: 2,
            changes: [
                FeedChange(
                    cursor: 2, operationID: UUID(), deviceID: UUID(), sequence: 1,
                    requestedCaptureID: original.id, capture: substituted)
            ])
        let transport = ResponseTransport(
            server: f.server,
            snapshot: baseline
                ? Baseline(cursor: 2, captures: [substituted], deviceSequences: [:]) : nil,
            page: baseline ? nil : page, onDownload: { probe.record() })
        #expect(throws: SyncError.invalidOperation) { try f.client.pull(from: transport) }
        #expect(try f.client.cursor() == 1)
        #expect(try f.client.captures() == before)
        #expect(probe.count == 0)
    }

    @Test(arguments: [false, true])
    func invalidLocalFeedAliasIsRejectedBeforeCaching(asynchronous: Bool) async throws {
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let f = try ResponseFixture(binding: binding)
        defer { f.clean() }
        let pending = f.capture("pending local work")
        let operation = try f.client.enqueue(captureID: pending.id, mutation: .create(pending))
        let before = try f.durableState()
        let files = try FileManager.default.contentsOfDirectory(
            atPath: f.client.blobs.directory.path)
        let probe = DownloadProbe()
        for _ in 0..<2 {
            let blob = try f.server.blobs.put(Data(UUID().uuidString.utf8))
            var capture = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
            capture.revision = 1
            var invalid = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
            invalid.revision = 2
            let page = FeedPage(
                cursor: 2,
                changes: [
                    FeedChange(
                        cursor: 1, operationID: UUID(), deviceID: UUID(), sequence: 1,
                        requestedCaptureID: capture.id, capture: capture),
                    FeedChange(
                        cursor: 2, operationID: UUID(), deviceID: f.client.deviceID, sequence: 1,
                        requestedCaptureID: UUID(), capture: invalid),
                ])
            if asynchronous {
                let transport = LocalFeedWire(
                    binding: binding, deviceID: f.client.deviceID,
                    server: f.server, page: page, probe: probe)
                await #expect(throws: SyncError.invalidOperation) {
                    try await f.client.pull(from: transport, credential: { "synthetic" })
                }
            } else {
                let transport = BoundResponseTransport(
                    transport: ResponseTransport(
                        server: f.server, page: page, onDownload: { probe.record() }),
                    binding: binding, deviceID: f.client.deviceID)
                #expect(throws: SyncError.invalidOperation) { try f.client.pull(from: transport) }
            }
            #expect(probe.count == 0)
            #expect(try f.durableState() == before)
            #expect(try f.client.cursor() == 0)
            #expect(try f.client.pendingOperations() == [operation])
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: f.client.blobs.directory.path)
                    == files)
        }
    }

    @Test func samePageLocalAliasAndDependentEditRemainValid() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let download = try f.server.blobs.put(Data("new remote image".utf8))
        let remote = SharedCapture(source: CaptureSource(kind: .image, blob: download))
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1,
                captureID: remote.id, baseRevision: 0, mutation: .create(remote)))
        let bytes = Data("same-page image alias".utf8)
        let blob = try f.server.blobs.put(bytes)
        let original = SharedCapture(
            source: CaptureSource(kind: .image, contentHash: blob.digest, blob: blob))
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1,
                captureID: original.id, baseRevision: 0, mutation: .create(original)))
        _ = try f.client.blobs.put(bytes)
        let duplicate = SharedCapture(source: original.source)
        let create = try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        let edit = try f.client.enqueue(
            captureID: duplicate.id,
            mutation: .edit(CaptureEdit(note: NoteEdit("dependent note"))))
        _ = try f.server.apply(create)
        _ = try f.server.apply(edit)
        let client = f.client
        let writer = f.writer
        let probe = DownloadProbe()
        try client.pull(
            from: ResponseTransport(
                server: f.server,
                onDownload: {
                    probe.record()
                    #expect((try? client.cursor()) == 0)
                    #expect((try? client.pendingOperations()) == [create, edit])
                    for table in ["sync_records", "sync_receipts", "sync_aliases", "sync_observed"]
                    {
                        #expect(
                            (try? writer.read {
                                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")
                            }) == 0)
                    }
                }))
        #expect(probe.count == 1)
        #expect(try f.client.cursor() == 4)
        #expect(try f.client.captures().first { $0.id == original.id }?.note == "dependent note")
        #expect(try f.client.pendingOperations() == [create, edit])
        try f.client.push(to: f.server)
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test func samePageIdentitySubstitutionIsRejectedBeforeCaching() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        var first = f.capture("new page identity")
        first.revision = 1
        let blob = try f.server.blobs.put(Data("same page substitute".utf8))
        var substituted = SharedCapture(
            id: first.id, source: CaptureSource(kind: .image, blob: blob),
            createdAt: first.createdAt)
        substituted.revision = 2
        let device = UUID()
        let page = FeedPage(
            cursor: 2,
            changes: [first, substituted].map {
                FeedChange(
                    cursor: $0.revision, operationID: UUID(), deviceID: device,
                    sequence: $0.revision, requestedCaptureID: first.id, capture: $0)
            })
        let probe = DownloadProbe()
        #expect(throws: SyncError.invalidOperation) {
            try f.client.pull(
                from: ResponseTransport(
                    server: f.server, page: page, onDownload: { probe.record() }))
        }
        #expect(try f.client.cursor() == 0)
        #expect(try f.client.captures().isEmpty)
        #expect(probe.count == 0)
    }

    @Test(arguments: [false, true])
    func ratingPredecessorCannotAuthorizeNoteOverwrite(earlierNote: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("rating predecessor")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        var remoteBase: Int64 = 1
        if earlierNote {
            let first = try f.client.enqueue(
                captureID: original.id, mutation: .edit(CaptureEdit(note: NoteEdit("First"))))
            remoteBase = try #require(f.server.apply(first).capture).revision
        }
        let rating = try f.client.enqueue(
            captureID: original.id, mutation: .edit(CaptureEdit(rating: 4)))
        let note = try f.client.enqueue(
            captureID: original.id, mutation: .edit(CaptureEdit(note: NoteEdit("Local"))))
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: original.id, baseRevision: remoteBase,
                mutation: .edit(CaptureEdit(note: NoteEdit("Remote")))))
        let rated = try f.server.apply(rating)
        let legitimate = try f.server.apply(note)
        #expect(legitimate.outcome == .noteConflict)
        var overwritten = try #require(rated.capture)
        overwritten.revision = try #require(legitimate.capture).revision
        _ = try SyncDatabase.edit(
            &overwritten, CaptureEdit(note: NoteEdit("Local")), operation: note,
            base: overwritten.noteRevision, server: true)
        let forged = SyncReceipt(operationID: note.id, outcome: .accepted, capture: overwritten)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [note])
        #expect(try f.writer.read { try SyncDatabase.record($0, id: original.id) } == rated.capture)
        #expect(try f.client.push(to: f.server) == [legitimate])
        try f.client.pull(from: f.server)
        #expect(
            Set(try f.client.captures().first!.noteConflicts.compactMap(\.value)) == [
                "Remote", "Local",
            ])
    }

    @Test(arguments: [false, true])
    func unobservedNoteConflictMustAdvanceBaseAndCurrent(advancesBase: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("stale conflict")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let operation = try f.client.enqueue(
            captureID: original.id, mutation: .edit(CaptureEdit(note: NoteEdit("Local"))))
        let remoteDevice = UUID()
        for sequence in 1...2 {
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: remoteDevice, sequence: Int64(sequence), captureID: original.id,
                    baseRevision: 1, mutation: .edit(CaptureEdit(rating: sequence + 2))))
        }
        try f.client.pull(from: f.server)
        let before = try f.client.captures()
        var stale = try #require(f.server.baseline().captures.first)
        stale.revision = advancesBase ? 2 : operation.baseRevision
        stale.noteConflicts = [NoteVariant(operationID: operation.id, value: "Local")]
        let forged = SyncReceipt(operationID: operation.id, outcome: .noteConflict, capture: stale)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == before)
        #expect(try f.client.push(to: f.server).first?.outcome == .accepted)
        #expect(try f.client.captures().first?.note == "Local")
    }

    @Test(arguments: ["direct", "reopen", "feed"])
    func causalQueuedNotesStillProduceCompleteAcceptedTransitions(recovery: String) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("queued note")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let first = try f.client.enqueue(
            captureID: original.id, mutation: .edit(CaptureEdit(note: NoteEdit("First"))))
        let rating = try f.client.enqueue(
            captureID: original.id, mutation: .edit(CaptureEdit(rating: 4)))
        let second = try f.client.enqueue(
            captureID: original.id, mutation: .edit(CaptureEdit(note: NoteEdit("Second"))))
        let client: SyncClient
        if recovery == "feed" {
            _ = try f.server.apply(first)
            _ = try f.server.apply(rating)
            try f.client.pull(from: f.server)
            #expect(
                try f.writer.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_receipts")
                } == 2)
            _ = try f.server.apply(second)
            try f.client.pull(from: f.server)
            #expect(try f.client.pendingOperations() == [first, rating, second])
        }
        if recovery == "reopen" {
            #expect(throws: SyncError.acknowledgementLost) {
                try f.client.push(
                    to: ResponseTransport(server: f.server, failureOperationID: second.id))
            }
            #expect(try f.client.pendingOperations() == [second])
            #expect(
                try f.writer.read {
                    try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_receipts")
                } == 2)
            client = try SyncClient(writer: f.writer, blobs: f.client.blobs)
            #expect(try client.push(to: f.server).map(\.outcome) == [.accepted])
        } else {
            client = f.client
            #expect(
                try client.push(to: f.server).map(\.outcome) == [.accepted, .accepted, .accepted])
        }
        #expect(try client.captures().first?.note == "Second")
        #expect(try client.captures().first?.noteConflicts.isEmpty == true)
        #expect(
            try f.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_receipts") }
                == 0)
    }

    @Test func unicodeEquivalentFingerprintsAgreeAcrossClientAuthorityAndStaging() throws {
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let f = try ResponseFixture(binding: binding)
        defer { f.clean() }
        let transport = BoundResponseTransport(
            transport: ResponseTransport(server: f.server), binding: binding,
            deviceID: f.client.deviceID)
        let first = SharedCapture(source: CaptureSource(kind: .text, contentHash: "café"))
        let duplicate = SharedCapture(
            source: CaptureSource(kind: .text, contentHash: "cafe\u{301}"))
        #expect(first.source.contentHash == duplicate.source.contentHash)
        #expect(Set([first.source.contentHash!, duplicate.source.contentHash!]).count == 1)
        try f.client.enqueue(captureID: first.id, mutation: .create(first))
        try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        #expect(try f.client.captures().count == 1)
        #expect(try f.client.captures().first?.seenCount == 2)
        #expect(try f.client.push(to: transport).map { $0.capture?.id } == [first.id, first.id])
        #expect(try f.client.pendingOperations().isEmpty)
        let stagedFirst = SharedCapture(source: CaptureSource(kind: .text, contentHash: "résumé"))
        let stagedDuplicate = SharedCapture(
            source: CaptureSource(kind: .text, contentHash: "re\u{301}sume\u{301}"))
        let snapshot = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: binding, sourceDeviceID: UUID(),
            captures: [stagedFirst, stagedDuplicate])
        let preview = try f.server.previewContentSnapshotImport(snapshot)
        #expect(Set(preview.items.map(\.canonicalCaptureID)).count == 1)
        #expect(Set(preview.items.map(\.disposition)) == [.insert, .merge])
        _ = try f.server.importContentSnapshot(snapshot, preview: preview)
        #expect(try f.server.baseline().captures.count == 2)
    }

    @Test(arguments: [100, Int.max], [false, true])
    func nextRevisionCountCannotInflate(count: Int, duplicateCreate: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("inflated")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let operation: SyncOperation
        if duplicateCreate {
            let duplicate = SharedCapture(source: original.source)
            operation = try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        } else {
            operation = try f.client.enqueue(captureID: original.id, mutation: .recapture)
        }
        let before = try f.client.captures()
        var inflated = try #require(f.server.baseline().captures.first)
        inflated.revision += 1
        inflated.seenCount = count
        let forged = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: inflated)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == before)
    }

    @Test(arguments: ["note", "revision", "operation", "conflicts"])
    func noNoteEditPreservesNextRevisionNoteTuple(field: String) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        var original = f.capture("untouched note")
        original.note = "Original"
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let operation = try f.client.enqueue(
            captureID: original.id, mutation: .edit(CaptureEdit(rating: 5)))
        let before = try f.client.captures()
        var changed = try #require(f.server.baseline().captures.first)
        changed.revision += 1
        changed.rating = 5
        switch field {
        case "note": changed.note = "Unrequested"
        case "revision": changed.noteRevision = changed.revision
        case "operation": changed.noteOperationID = UUID()
        default: changed.noteConflicts = [NoteVariant(operationID: UUID(), value: "Unrequested")]
        }
        let forged = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: changed)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == before)
    }

    @Test func noNoteEditAllowsUnseenConcurrentNoteChange() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("concurrent note")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.enqueue(captureID: original.id, mutation: .edit(CaptureEdit(rating: 5)))
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: original.id, baseRevision: 1,
                mutation: .edit(CaptureEdit(note: NoteEdit("Remote")))))
        #expect(try f.client.push(to: f.server).first?.outcome == .accepted)
        let accepted = try #require(f.client.captures().first)
        #expect(accepted.note == "Remote")
        #expect(accepted.rating == 5)
        #expect(accepted.revision == 3)
    }

    @Test(arguments: [100, Int.max], [false, true])
    func unseenSnapshotImportCanGrowCountsBeyondRevisionDelta(
        count: Int, duplicateCreate: Bool
    ) throws {
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let f = try ResponseFixture(binding: binding)
        defer { f.clean() }
        let transport = BoundResponseTransport(
            transport: ResponseTransport(server: f.server), binding: binding,
            deviceID: f.client.deviceID)
        let original = f.capture("imported count")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: transport)
        if duplicateCreate {
            let duplicate = SharedCapture(source: original.source)
            try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        } else {
            try f.client.enqueue(captureID: original.id, mutation: .recapture)
        }
        var imported = original
        imported.seenCount = count
        let snapshot = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: binding, sourceDeviceID: UUID(), captures: [imported]
        )
        _ = try f.server.importContentSnapshot(
            snapshot, preview: f.server.previewContentSnapshotImport(snapshot))
        let expected = count == Int.max ? count : count + 1
        let accepted = try #require(f.client.push(to: transport).first?.capture)
        #expect(accepted.revision == 3)
        #expect(accepted.seenCount == expected)
        #expect(try f.client.pendingOperations().isEmpty)
        try f.client.pull(from: transport)
        #expect(try f.client.captures().first?.seenCount == expected)
    }

    @Test func acknowledgedFeedEchoesDoNotAccumulateMarkers() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("acknowledged markers")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        for _ in 0..<3 {
            try f.client.enqueue(captureID: original.id, mutation: .recapture)
            try f.client.push(to: f.server)
            try f.client.pull(from: f.server)
        }
        #expect(try f.observedIDs().isEmpty)
        #expect(try f.client.captures().first?.seenCount == 4)
    }

    @Test func pendingObservationSurvivesReopenAndBaselineThenDrainsWithReceipt() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("pending marker")
        let operation = try f.client.enqueue(captureID: original.id, mutation: .create(original))
        let historical = try f.server.apply(operation)
        try f.client.pull(from: f.server)
        #expect(try f.observedIDs() == [operation.id.uuidString])
        try f.writer.write { db in
            for _ in 0..<3 {
                try db.execute(
                    sql: "INSERT INTO sync_observed (id) VALUES (?)", arguments: [UUID().uuidString]
                )
            }
        }
        let reopened = try SyncClient(
            databaseURL: f.root.appendingPathComponent("client.sqlite"),
            blobDirectory: f.root.appendingPathComponent("client-blobs"),
            deviceID: f.client.deviceID)
        #expect(try f.observedIDs() == [operation.id.uuidString])
        try reopened.pull(
            from: ResponseTransport(server: f.server, snapshot: f.server.baseline()))
        #expect(try f.observedIDs() == [operation.id.uuidString])
        #expect(try reopened.captures().first?.seenCount == 1)
        #expect(try reopened.push(to: f.server) == [historical])
        #expect(try f.observedIDs().isEmpty)
        #expect(try reopened.pendingOperations().isEmpty)
        try reopened.pull(from: f.server)
        #expect(try f.observedIDs().isEmpty)
    }

    @Test(arguments: [false, true])
    func legacyOrphansAreCompactedBeforeProjectionAndRecovery(baseline: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        try f.writer.write { db in
            for _ in 0..<3 {
                try db.execute(
                    sql: "INSERT INTO sync_observed (id) VALUES (?)", arguments: [UUID().uuidString]
                )
            }
        }
        if baseline {
            try f.client.pull(
                from: ResponseTransport(server: f.server, snapshot: f.server.baseline()))
        } else {
            let original = f.capture("legacy marker")
            try f.client.enqueue(captureID: original.id, mutation: .create(original))
            #expect(try f.client.captures() == [original])
        }
        #expect(try f.observedIDs().isEmpty)
    }

    @Test func sameIDCreateReceiptMustPreserveSource() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let incoming = f.capture("incoming")
        let operation = try f.client.enqueue(captureID: incoming.id, mutation: .create(incoming))
        var unrelated = SharedCapture(id: incoming.id, source: f.capture("unrelated").source)
        unrelated.revision = 1
        let receipt = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: unrelated)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: receipt))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == [incoming])
    }

    @Test(arguments: [false, true])
    func recaptureReceiptMustAdvanceRevisionAndCount(advanceRevision: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("recapture")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let operation = try f.client.enqueue(captureID: original.id, mutation: .recapture)
        let before = try f.client.captures()
        var unchanged = try #require(f.server.baseline().captures.first)
        if advanceRevision { unchanged.revision += 1 }
        let receipt = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: unchanged)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: receipt))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == before)
    }

    @Test(arguments: [false, true], [false, true])
    func baselineMustRetainAcceptedRevisions(omitted: Bool, tombstone: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("baseline dominance")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        let created = try #require(f.client.push(to: f.server).first?.capture)
        try f.client.enqueue(captureID: original.id, mutation: .edit(CaptureEdit(rating: 5)))
        try f.client.push(to: f.server)
        if tombstone {
            try f.client.enqueue(captureID: original.id, mutation: .delete)
            try f.client.push(to: f.server)
        }
        let queued = f.capture("observed pending create")
        let create = try f.client.enqueue(captureID: queued.id, mutation: .create(queued))
        _ = try f.server.apply(create)
        try f.client.pull(from: f.server)
        try f.client.enqueue(
            captureID: queued.id, mutation: .edit(CaptureEdit(note: NoteEdit("Queued"))))
        let authority = try f.server.baseline()
        let blob = try f.server.blobs.put(Data("baseline asset".utf8))
        var asset = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        asset.revision = authority.cursor + 1
        let captures =
            [asset] + authority.captures.filter { $0.id != original.id }
            + (omitted ? [] : [created])
        let baseline = Baseline(
            cursor: asset.revision, captures: captures, deviceSequences: authority.deviceSequences)
        let before = try f.durableState()
        let files = try FileManager.default.contentsOfDirectory(
            atPath: f.client.blobs.directory.path)
        let probe = DownloadProbe()
        #expect(throws: SyncError.invalidCursor) {
            try f.client.pull(
                from: ResponseTransport(
                    server: f.server, snapshot: baseline, onDownload: { probe.record() }))
        }
        #expect(try f.durableState() == before)
        #expect(probe.count == 0)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: f.client.blobs.directory.path)
                == files)
        try f.client.push(to: f.server)
        #expect(try f.client.pendingOperations().isEmpty)
        #expect(try f.client.captures().first(where: { $0.id == queued.id })?.note == "Queued")
    }

    @Test func baselineDominanceIsRecheckedAfterAssetDownload() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("baseline download race")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        let historical = try f.server.baseline()
        let blob = try f.server.blobs.put(Data("racing baseline asset".utf8))
        var asset = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        asset.revision = historical.cursor + 1
        let baseline = Baseline(
            cursor: asset.revision, captures: historical.captures + [asset],
            deviceSequences: historical.deviceSequences)
        let client = f.client
        let server = f.server
        let probe = DownloadProbe()
        #expect(throws: SyncError.invalidCursor) {
            try client.pull(
                from: ResponseTransport(
                    server: server, snapshot: baseline,
                    onDownload: {
                        probe.record()
                        try! client.enqueue(
                            captureID: original.id, mutation: .edit(CaptureEdit(rating: 5)))
                        try! client.push(to: server)
                    }))
        }
        let accepted = try #require(server.baseline().captures.first)
        #expect(probe.count == 1)
        #expect(try client.cursor() == historical.cursor)
        #expect(try f.writer.read { try SyncDatabase.records($0) } == [accepted])
        #expect(try client.captures() == [accepted])
        #expect(try client.pendingOperations().isEmpty)
        #expect(try f.observedIDs().isEmpty)
        #expect(try f.writer.read { try SyncDatabase.canonical($0, asset.id) } == asset.id)
    }

    @Test(arguments: [false, true])
    func baselinePreservesAcknowledgementsAheadOfCursor(omitted: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("acknowledgement ahead")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        let historical = try f.server.baseline()
        try f.client.enqueue(captureID: original.id, mutation: .edit(CaptureEdit(rating: 5)))
        let accepted = try #require(f.client.push(to: f.server).first?.capture)
        try f.client.enqueue(
            captureID: original.id, mutation: .edit(CaptureEdit(note: NoteEdit("Queued"))))
        let unsent = f.capture("pending only")
        try f.client.enqueue(captureID: unsent.id, mutation: .create(unsent))
        let visible = try f.client.captures()
        let pending = try f.client.pendingOperations()
        let baseline = Baseline(
            cursor: historical.cursor, captures: omitted ? [] : historical.captures,
            deviceSequences: historical.deviceSequences)
        try f.client.pull(from: ResponseTransport(server: f.server, snapshot: baseline))
        #expect(try f.writer.read { try SyncDatabase.record($0, id: original.id) } == accepted)
        #expect(try f.client.captures() == visible)
        #expect(try f.client.pendingOperations() == pending)
        #expect(try f.client.cursor() == historical.cursor)
        try f.client.push(to: f.server)
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test(arguments: [-1, 3])
    func baselineRevisionMustBeWithinSnapshot(revision: Int64) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("baseline")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        let before = try f.client.captures()
        var poisoned = try #require(before.first)
        poisoned.revision = revision
        let baseline = Baseline(cursor: 2, captures: [poisoned], deviceSequences: [:])
        #expect(throws: SyncError.invalidCursor) {
            try f.client.pull(from: ResponseTransport(server: f.server, snapshot: baseline))
        }
        #expect(try f.client.captures() == before)
        #expect(try f.client.cursor() == 1)
    }

    @Test func duplicateBaselineIDsDoNotReplaceShadow() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        for name in ["first", "second"] {
            let record = f.capture(name)
            try f.client.enqueue(captureID: record.id, mutation: .create(record))
        }
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        let before = try f.client.captures()
        let first = try #require(before.first)
        let baseline = Baseline(cursor: 2, captures: [first, first], deviceSequences: [:])
        #expect(throws: SyncError.invalidCursor) {
            try f.client.pull(from: ResponseTransport(server: f.server, snapshot: baseline))
        }
        #expect(try f.client.captures() == before)
        #expect(try f.client.cursor() == 2)
    }

    @Test(arguments: [false, true])
    func uncorrelatedLocalFeedAliasRollsBack(pending: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let incoming = f.capture("requested")
        let operation =
            pending
            ? try f.client.enqueue(captureID: incoming.id, mutation: .create(incoming))
            : SyncOperation(
                deviceID: f.client.deviceID, sequence: 1, captureID: incoming.id,
                baseRevision: 0, mutation: .create(incoming))
        let before = try f.client.captures()
        var unrelated = f.capture("unrelated")
        unrelated.revision = 1
        let page = FeedPage(
            cursor: 1,
            changes: [
                FeedChange(
                    cursor: 1, operationID: operation.id, deviceID: f.client.deviceID,
                    sequence: operation.sequence, requestedCaptureID: incoming.id,
                    capture: unrelated)
            ])
        #expect(throws: SyncError.invalidOperation) {
            try f.client.pull(from: ResponseTransport(server: f.server, page: page))
        }
        #expect(try f.client.captures() == before)
        #expect(try f.client.cursor() == 0)
        let alias = try f.writer.read { try SyncDatabase.canonical($0, incoming.id) }
        let observed = try f.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_observed")
        }
        #expect(alias == incoming.id)
        #expect(observed == 0)
        if pending {
            #expect(try f.client.pendingOperations() == [operation])
            try f.client.push(to: f.server)
        }
    }

    @Test func historicalReceiptsSurviveOwnEchoAndLaterRemoteEdits() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        var record = f.capture("historical")
        record.source.title = ""
        record.source.selection = ""
        try f.client.enqueue(captureID: record.id, mutation: .create(record))
        try f.client.push(to: f.server)
        let recapture = try f.client.enqueue(captureID: record.id, mutation: .recapture)
        let historical = try f.server.apply(recapture)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: record.id,
                baseRevision: historical.capture!.revision,
                mutation: .edit(
                    CaptureEdit(
                        rating: 5,
                        sourceContent: SourceContentPatch(
                            title: "Filled title", selection: "Filled text")))))
        try f.client.pull(from: f.server)
        let latest = try f.client.captures()
        #expect(try f.client.push(to: f.server) == [historical])
        #expect(try f.client.captures() == latest)
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test func remoteShadowDoesNotProvePendingOperationWasAccepted() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("unobserved")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let operation = try f.client.enqueue(captureID: original.id, mutation: .recapture)
        let remote = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: original.id,
                baseRevision: operation.baseRevision, mutation: .recapture))
        try f.client.pull(from: f.server)
        let before = try f.client.captures()
        let forged = SyncReceipt(
            operationID: operation.id, outcome: .accepted, capture: remote.capture)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == before)
        try f.client.push(to: f.server)
        #expect(try f.client.captures().first?.seenCount == 3)
    }

    @Test func unchangedRecaptureEchoCannotProveAcceptance() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("unchanged echo")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        let operation = try f.client.enqueue(captureID: original.id, mutation: .recapture)
        let before = try f.client.captures()
        var unchanged = try #require(f.server.baseline().captures.first)
        unchanged.revision += 1
        let page = FeedPage(
            cursor: unchanged.revision,
            changes: [
                FeedChange(
                    cursor: unchanged.revision, operationID: operation.id,
                    deviceID: f.client.deviceID, sequence: operation.sequence,
                    requestedCaptureID: original.id, capture: unchanged)
            ])
        let forged = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: unchanged)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.pull(from: ResponseTransport(server: f.server, page: page))
        }
        #expect(try f.client.cursor() == operation.baseRevision)
        #expect(try f.client.captures() == before)
        let observed = try f.writer.read {
            try Int.fetchOne(
                $0, sql: "SELECT COUNT(*) FROM sync_observed WHERE id = ?",
                arguments: [operation.id.uuidString])
        }
        #expect(observed == 0)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures() == before)
        try f.client.push(to: f.server)
        #expect(try f.client.captures().first?.seenCount == 2)
    }

    @Test(arguments: [false, true], [false, true])
    func pendingNoteConflictEchoRemainsValid(duplicateCreate: Bool, laterRemoteEdit: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("conflict echo")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: original.id, baseRevision: 1,
                mutation: .edit(CaptureEdit(note: NoteEdit("Remote")))))
        let operation: SyncOperation
        if duplicateCreate {
            let duplicate = SharedCapture(source: original.source, note: "Local")
            operation = try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        } else {
            operation = try f.client.enqueue(
                captureID: original.id, mutation: .edit(CaptureEdit(note: NoteEdit("Local"))))
        }
        let historical = try f.server.apply(operation)
        #expect(historical.outcome == .noteConflict)
        if laterRemoteEdit {
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: original.id,
                    baseRevision: try #require(historical.capture).revision,
                    mutation: .edit(CaptureEdit(rating: 5))))
        }
        try f.client.pull(from: f.server)
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.push(to: f.server) == [historical])
        let accepted = try #require(f.client.captures().first)
        #expect(Set(accepted.noteConflicts.compactMap(\.value)) == ["Remote", "Local"])
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test func acceptedEditReceiptMustContainRequestedRating() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("edit")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        let operation = try f.client.enqueue(
            captureID: original.id, mutation: .edit(CaptureEdit(rating: 5)))
        var unchanged = try #require(f.server.baseline().captures.first)
        unchanged.revision += 1
        let forged = SyncReceipt(operationID: operation.id, outcome: .accepted, capture: unchanged)
        #expect(throws: SyncError.invalidOperation) {
            try f.client.push(to: ResponseTransport(server: f.server, receipt: forged))
        }
        #expect(try f.client.pendingOperations() == [operation])
        #expect(try f.client.captures().first?.rating == 5)
    }

    @Test(arguments: [Int.max - 1, Int.max])
    func acceptedRecaptureCountCanSaturate(count: Int) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("saturated")
        try f.client.enqueue(captureID: original.id, mutation: .create(original))
        try f.client.push(to: f.server)
        var current = try #require(f.server.baseline().captures.first)
        current.seenCount = count
        let authority = try SyncDatabase.open(at: f.root.appendingPathComponent("server.sqlite"))
        try authority.write { try SyncDatabase.save($0, current) }
        try f.writer.write { try SyncDatabase.save($0, current) }
        try f.client.enqueue(captureID: original.id, mutation: .recapture)
        #expect(try f.client.push(to: f.server).first?.capture?.seenCount == Int.max)
        #expect(try f.client.pendingOperations().isEmpty)
        #expect(try f.client.captures().first?.seenCount == Int.max)
    }

    @Test(arguments: [false, true])
    func acceptedExistingNoteVariantRemainsValid(duplicateCreate: Bool) throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let original = f.capture("conflict")
        let created = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: original.id, baseRevision: 0,
                mutation: .create(original)))
        let base = try #require(created.capture).revision
        for value in ["A", "B"] {
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: original.id, baseRevision: base,
                    mutation: .edit(CaptureEdit(note: NoteEdit(value)))))
        }
        try f.client.pull(from: f.server)
        if duplicateCreate {
            let duplicate = SharedCapture(source: original.source, note: "B")
            try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        } else {
            try f.client.enqueue(
                captureID: original.id, mutation: .edit(CaptureEdit(note: NoteEdit("B"))),
                baseRevision: base)
        }
        #expect(try f.client.push(to: f.server).first?.outcome == .accepted)
        let accepted = try #require(f.client.captures().first)
        #expect(accepted.note == "A")
        #expect(Set(accepted.noteConflicts.compactMap(\.value)) == ["A", "B"])
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test func pendingDeduplicatedCreateAndEstablishedAliasFeedRemainValid() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let first = f.capture("dedup")
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: first.id, baseRevision: 0,
                mutation: .create(first)))
        let duplicate = SharedCapture(source: first.source)
        let create = try f.client.enqueue(captureID: duplicate.id, mutation: .create(duplicate))
        _ = try f.server.apply(create)
        try f.client.pull(from: f.server)
        #expect(try f.client.captures().first?.seenCount == 2)
        try f.client.push(to: f.server)
        let edit = try f.client.enqueue(
            captureID: duplicate.id, mutation: .edit(CaptureEdit(rating: 4)))
        try f.client.push(to: f.server)
        try f.client.pull(from: f.server)
        #expect(try f.client.captures().first?.rating == 4)
        #expect(edit.captureID == duplicate.id)
        #expect(try f.client.pendingOperations().isEmpty)
    }

    @Test func exhaustedSequenceThrowsWithoutMutatingOutbox() throws {
        let f = try ResponseFixture()
        defer { f.clean() }
        let baseline = Baseline(
            cursor: 0, captures: [], deviceSequences: [f.client.deviceID: Int64.max])
        try f.client.pull(from: ResponseTransport(server: f.server, snapshot: baseline))
        let record = f.capture("exhausted")
        #expect(throws: SyncError.invalidOperation) {
            try f.client.enqueue(captureID: record.id, mutation: .create(record))
        }
        #expect(try f.client.pendingOperations().isEmpty)
        #expect(try f.client.captures().isEmpty)
        #expect(
            try f.writer.read { try Int64.fetchOne($0, sql: "SELECT sequence FROM sync_meta") }
                == Int64.max)
    }
}

private struct ResponseTransport: SyncTransport {
    let server: SyncServer
    var receipt: SyncReceipt? = nil
    var snapshot: Baseline? = nil
    var page: FeedPage? = nil
    var onDownload: (@Sendable () -> Void)? = nil
    var failureOperationID: UUID? = nil

    func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        if operation.id == failureOperationID {
            _ = try server.apply(operation)
            throw SyncError.acknowledgementLost
        }
        if let receipt, receipt.operationID == operation.id { return receipt }
        return try server.apply(operation)
    }

    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        if snapshot != nil { throw SyncError.cursorExpired }
        if let page { return page }
        return try server.changes(after: cursor, limit: limit)
    }

    func baseline() throws -> Baseline {
        if let snapshot { return snapshot }
        return try server.baseline()
    }

    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(blob, offset: offset, chunk: chunk, final: final)
    }

    func download(_ blob: BlobReference) throws -> Data {
        onDownload?()
        return try server.download(blob)
    }
}

private final class DownloadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var downloads = 0
    var count: Int { lock.withLock { downloads } }
    func record() { lock.withLock { downloads += 1 } }
}

private struct ResponseFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let writer: DatabasePool
    let client: SyncClient
    let server: SyncServer

    init(binding: SyncLibraryBinding? = nil) throws {
        writer = try SyncDatabase.open(at: root.appendingPathComponent("client.sqlite"))
        client = try SyncClient(
            writer: writer,
            blobs: BlobStore(
                directory: root.appendingPathComponent("client-blobs"), binding: binding),
            binding: binding
        )
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("server-blobs"),
            libraryID: binding?.libraryID, serviceID: binding?.serviceID)
    }

    func capture(_ value: String) -> SharedCapture {
        SharedCapture(source: CaptureSource(kind: .text, contentHash: value, selection: value))
    }

    func clean() { try? FileManager.default.removeItem(at: root) }

    func durableState() throws -> [String: [Row]] {
        try writer.read { db in
            var state: [String: [Row]] = [:]
            for table in [
                "sync_meta", "sync_records", "sync_visible", "sync_outbox", "sync_aliases",
                "sync_observed", "sync_receipts", "sync_rejections",
            ] {
                state[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            }
            return state
        }
    }

    func observedIDs() throws -> Set<String> {
        try writer.read { try String.fetchSet($0, sql: "SELECT id FROM sync_observed") }
    }
}

private struct BoundResponseTransport: BoundSyncTransport {
    let transport: ResponseTransport
    let binding: SyncLibraryBinding
    let deviceID: UUID

    func apply(_ operation: SyncOperation) throws -> SyncReceipt { try transport.apply(operation) }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try transport.changes(after: cursor, limit: limit)
    }
    func baseline() throws -> Baseline { try transport.baseline() }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try transport.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data { try transport.download(blob) }
}

private struct LocalFeedWire: AsyncSyncTransport {
    let binding: SyncLibraryBinding
    let deviceID: UUID
    let server: SyncServer
    let page: FeedPage
    let probe: DownloadProbe
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        let envelope = try SyncDatabase.decode(SyncHTTPEnvelope.self, request.body)
        let result: SyncHTTPResult
        switch envelope.action {
        case .changes: result = .page(page)
        case .download(let blob):
            probe.record()
            result = .data(try server.download(blob))
        default: throw SyncHTTPError.invalidResponse
        }
        return SyncHTTPResponse(
            status: 200, headers: ["Content-Type": "application/json"],
            body: try SyncDatabase.encode(
                SyncHTTPReply(
                    version: 1,
                    principal: SyncPrincipal(
                        serviceID: binding.serviceID,
                        libraryID: binding.libraryID, deviceID: deviceID), result: result)))
    }
}
