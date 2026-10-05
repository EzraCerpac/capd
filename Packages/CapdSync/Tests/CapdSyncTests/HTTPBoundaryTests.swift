import Foundation
import Testing

@testable import CapdSync

@Suite("Prepared authenticated sync boundary")
struct HTTPBoundaryTests {
    @Test func incompleteNativeBaselineIsRejectedBeforeDownloadingBlobs() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("native-baseline")
        let original = SharedCapture(source: CaptureSource(kind: .text, selection: "original"))
        try client.enqueue(captureID: original.id, mutation: .create(original))
        try client.push(to: f.transport("A"))
        try client.pull(from: f.transport("A"))
        let before = try client.captures()
        let bytes = Data("synthetic baseline image".utf8)
        var image = SharedCapture(
            source: CaptureSource(kind: .image, blob: BlobReference(data: bytes)))
        image.revision = 2
        let downloads = Counter()
        let transport = IncompleteBaselineTransport(
            backing: f.transport("A"),
            snapshot: Baseline(
                cursor: 2, captures: [image], deviceSequences: [:], totalCaptureCount: 2),
            bytes: bytes, downloads: downloads)
        #expect(throws: SyncError.invalidCursor) { try client.pull(from: transport) }
        #expect(downloads.value == 0)
        #expect(try client.cursor() == 1)
        #expect(try client.captures() == before)
        #expect(throws: SyncError.blobMissing) { try client.blobs.read(image.source.blob!) }
    }

    @Test(arguments: [false, true], [Int64(0), 3])
    func feedCaptureRevisionMustMatchItsCursor(asynchronous: Bool, revision: Int64) async throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("feed-revision")
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "original"))
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        try client.push(to: f.transport("A"))
        try client.pull(from: f.transport("A"))
        let before = try client.captures()
        _ = try f.a.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: capture.id, baseRevision: 1,
                mutation: .edit(CaptureEdit(rating: 5))))
        let page = try f.a.changes(after: 1)
        var poisoned = page.changes[0].capture
        poisoned.revision = revision
        let change = page.changes[0]
        let result = SyncHTTPResult.page(
            FeedPage(
                cursor: page.cursor,
                changes: [
                    FeedChange(
                        cursor: change.cursor, operationID: change.operationID,
                        deviceID: change.deviceID, sequence: change.sequence,
                        requestedCaptureID: change.requestedCaptureID, capture: poisoned)
                ]))
        let execute: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse = { _ in
            try syntheticReply(result, principal: f.principal)
        }
        if asynchronous {
            await #expect(throws: SyncError.invalidCursor) {
                try await client.pull(
                    from: QualityWire(execute: execute, binding: f.binding, deviceID: f.device),
                    credential: { "A" })
            }
        } else {
            #expect(throws: SyncError.invalidCursor) {
                try client.pull(
                    from: SyncHTTPTransport(
                        binding: f.binding, deviceID: f.device, credential: { "A" },
                        execute: execute))
            }
        }
        #expect(try client.cursor() == 1)
        #expect(try client.captures() == before)
        try client.pull(from: f.transport("A"))
        #expect(try client.captures().first?.revision == 2)
        #expect(try client.captures().first?.rating == 5)
    }

    @Test(arguments: [false, true], ["short", "missingCount", "negativeCount", "inflatedCount"])
    func incompleteBaselineDoesNotDeleteShadows(asynchronous: Bool, corruption: String) async throws
    {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("incomplete-baseline")
        for index in 0..<3 {
            let record = SharedCapture(
                source: CaptureSource(kind: .text, selection: "row \(index)"))
            try client.enqueue(captureID: record.id, mutation: .create(record))
        }
        try client.push(to: f.transport("A"))
        try client.pull(from: f.transport("A"))
        let before = try client.captures()
        let cursor = try client.cursor()
        let extra = SharedCapture(source: CaptureSource(kind: .text, selection: "extra row"))
        _ = try f.a.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: extra.id, baseRevision: 0,
                mutation: .create(extra)))
        try f.a.expireFeed(through: cursor + 1)
        let execute: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse = { request in
            let response = f.handler.handle(request)
            var json = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
            var result = json["result"] as! [String: Any]
            if var container = result["baseline"] as? [String: Any],
                var baseline = container["_0"] as? [String: Any]
            {
                switch corruption {
                case "short":
                    baseline["captures"] = Array((baseline["captures"] as! [Any]).prefix(1))
                case "missingCount": baseline.removeValue(forKey: "totalCaptureCount")
                case "negativeCount": baseline["totalCaptureCount"] = -1
                default: baseline["totalCaptureCount"] = 5
                }
                container["_0"] = baseline
                result["baseline"] = container
                json["result"] = result
            }
            return SyncHTTPResponse(
                status: response.status, headers: response.headers,
                body: try JSONSerialization.data(withJSONObject: json))
        }
        if asynchronous {
            await #expect(throws: SyncHTTPError.invalidResponse) {
                try await client.pull(
                    from: QualityWire(execute: execute, binding: f.binding, deviceID: f.device),
                    credential: { "A" })
            }
        } else {
            #expect(throws: SyncHTTPError.invalidResponse) {
                try client.pull(
                    from: SyncHTTPTransport(
                        binding: f.binding, deviceID: f.device, credential: { "A" },
                        execute: execute))
            }
        }
        let reopened = try f.client("incomplete-baseline")
        #expect(try reopened.cursor() == cursor)
        #expect(try reopened.captures() == before)
        try reopened.pull(from: f.transport("A"))
        #expect(try reopened.captures().count == 4)
    }

    @Test(arguments: [false, true], InvalidReceipt.allCases)
    private func impossibleReceiptsPreserveDurableOutbox(
        asynchronous: Bool, invalid: InvalidReceipt
    ) async throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("invalid-receipt")
        let capture = SharedCapture(source: CaptureSource(kind: .text, contentHash: "original"))
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        try client.push(to: f.transport("A"))
        try client.pull(from: f.transport("A"))
        let duplicate = SharedCapture(source: CaptureSource(kind: .text, contentHash: "duplicate"))
        let mutation: CaptureMutation =
            invalid == .wrongCreateIdentity
            ? .create(duplicate)
            : invalid == .liveDelete ? .delete : .edit(CaptureEdit(rating: 4))
        let operation = try client.enqueue(
            captureID: invalid == .wrongCreateIdentity ? duplicate.id : capture.id,
            mutation: mutation)
        let before = try client.captures()
        var record = try #require(try f.a.baseline().captures.first)
        if invalid == .wrongIdentity || invalid == .wrongCreateIdentity {
            record = SharedCapture(source: record.source)
            record.revision = 1
        }
        let outcome: SyncReceipt.Outcome
        switch invalid {
        case .noteConflictWithoutCapture, .noteConflictWithoutNote: outcome = .noteConflict
        case .deletedWithoutCapture, .liveDeleted: outcome = .deleted
        case .staleRestoreWithoutCapture, .staleRestoreForEdit: outcome = .staleRestore
        case .alreadyExistsWithoutCapture, .alreadyExistsForEdit: outcome = .alreadyExists
        case .missingWithCapture: outcome = .missing
        default: outcome = .accepted
        }
        let receipt = SyncReceipt(
            operationID: operation.id, outcome: outcome,
            capture: invalid.rawValue.hasSuffix("WithoutCapture") ? nil : record)
        let execute: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse = { _ in
            try syntheticReply(.receipt(receipt), principal: f.principal)
        }
        if asynchronous {
            await #expect(throws: SyncError.invalidOperation) {
                try await client.push(
                    to: QualityWire(execute: execute, binding: f.binding, deviceID: f.device),
                    credential: { "A" })
            }
        } else {
            #expect(throws: SyncError.invalidOperation) {
                try client.push(
                    to: SyncHTTPTransport(
                        binding: f.binding, deviceID: f.device, credential: { "A" },
                        execute: execute))
            }
        }
        let reopened = try f.client("invalid-receipt")
        #expect(try reopened.pendingOperations() == [operation])
        #expect(try reopened.captures() == before)
        #expect(try reopened.rejectedWork().isEmpty)
        #expect(try reopened.push(to: f.transport("A")).map(\.operationID) == [operation.id])
        #expect(try reopened.pendingOperations().isEmpty)
    }

    @Test(arguments: [false, true], [0, 1, 2, 3])
    func skippedFeedCursorsLeaveDurableStateUnchanged(asynchronous: Bool, gap: Int) async throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("skipped-cursors")
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "accepted"))
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        try client.push(to: f.transport("A"))
        try client.pull(from: f.transport("A"))
        let pending = try client.enqueue(
            captureID: capture.id, mutation: .edit(CaptureEdit(rating: 3)))
        let before = try client.captures()
        let cursors: [Int64] = gap == 0 ? [3] : gap == 1 ? [2, 4] : gap == 2 ? [2, 3] : []
        let changes = cursors.map { cursor in
            var record = capture
            record.revision = cursor
            record.rating = 5
            return FeedChange(
                cursor: cursor, operationID: UUID(), deviceID: UUID(), sequence: cursor,
                requestedCaptureID: capture.id, capture: record)
        }
        let page = FeedPage(cursor: gap == 0 ? 3 : 4, changes: changes)
        let execute: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse = { _ in
            SyncHTTPResponse(
                status: 200, headers: ["Content-Type": "application/json"],
                body: try SyncDatabase.encode(
                    SyncHTTPReply(
                        version: 1,
                        principal: SyncPrincipal(
                            serviceID: f.service, libraryID: f.libraryA, deviceID: f.device),
                        result: .page(page))))
        }
        if asynchronous {
            let transport = QualityWire(execute: execute, binding: f.binding, deviceID: f.device)
            await #expect(throws: SyncError.invalidCursor) {
                try await client.pull(from: transport, credential: { "A" })
            }
        } else {
            let transport = SyncHTTPTransport(
                binding: f.binding, deviceID: f.device, credential: { "A" }, execute: execute)
            #expect(throws: SyncError.invalidCursor) { try client.pull(from: transport) }
        }
        #expect(try client.cursor() == 1)
        #expect(try client.captures() == before)
        #expect(try client.pendingOperations() == [pending])
        let reopened = try f.client("skipped-cursors")
        #expect(try reopened.cursor() == 1)
        #expect(try reopened.captures() == before)
        #expect(try reopened.pendingOperations() == [pending])
    }

    @Test(arguments: [false, true])
    func syncOnceRetriesExpiredAcknowledgementsButPreservesAmbiguousOutbox(
        ambiguousHistory: Bool
    ) async throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("expired-acknowledgement")
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "Lost receipt"))
        let operation = try client.enqueue(captureID: capture.id, mutation: .create(capture))
        _ = try f.a.apply(ambiguousHistory ? f.operation("Different accepted history") : operation)
        try f.a.expireFeed(through: f.a.baseline().cursor)
        let reopened = try f.client("expired-acknowledgement")
        let wire = RetainedImageWire(binding: f.binding, deviceID: f.device, handler: f.handler)
        if ambiguousHistory {
            await #expect(throws: SyncError.outOfOrder(expected: 2)) {
                try await reopened.syncOnce(using: wire, credential: { "A" })
            }
            #expect(try reopened.pendingOperations() == [operation])
            #expect(try reopened.cursor() == 0)
        } else {
            let receipts = try await reopened.syncOnce(using: wire, credential: { "A" })
            #expect(receipts.map(\.operationID) == [operation.id])
            #expect(try reopened.pendingOperations().isEmpty)
            #expect(try reopened.cursor() == f.a.baseline().cursor)
            #expect(try reopened.captures().first?.seenCount == 1)
            #expect(try reopened.enqueue(captureID: capture.id, mutation: .recapture).sequence == 2)
        }
    }

    @Test(arguments: [false, true], [Int?.none, 9])
    func requiredReceiptCapabilitiesRetainOperationAcrossBothExecutors(
        processing: Bool, marker: Int?
    ) async throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("capability-receipt")
        var capture = SharedCapture(
            source: CaptureSource(kind: .text, selection: "Receipt capability"),
            metadata: CaptureMetadata(sourceAppBundleID: "test.synthetic"))
        if processing {
            capture.generated = GeneratedContent(
                taggingProcessed: true, taggingInputFingerprint: "synthetic-fingerprint")
        }
        let operation = try client.enqueue(captureID: capture.id, mutation: .create(capture))
        let alterReceipt: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse = { request in
            let actual = f.handler.handle(request)
            let reply = try SyncDatabase.decode(SyncHTTPReply.self, actual.body)
            guard case .receipt = reply.result else { return actual }
            return SyncHTTPResponse(
                status: actual.status, headers: actual.headers,
                body: try SyncDatabase.encode(
                    SyncHTTPReply(
                        version: reply.version, principal: reply.principal, result: reply.result,
                        metadataContractVersion: processing
                            ? reply.metadataContractVersion : marker,
                        generatedProcessingContractVersion: processing
                            ? marker : reply.generatedProcessingContractVersion,
                        extractionQualityContractVersion: reply.extractionQualityContractVersion)))
        }
        #expect(throws: SyncHTTPError.unsupportedVersion) {
            try client.push(to: f.transport("A", executor: alterReceipt))
        }
        #expect(try client.pendingOperations() == [operation])
        let reopened = try f.client("capability-receipt")
        await #expect(throws: SyncHTTPError.unsupportedVersion) {
            try await reopened.push(
                to: QualityWire(execute: alterReceipt, binding: f.binding, deviceID: f.device),
                credential: { "A" })
        }
        #expect(try reopened.pendingOperations() == [operation])
        try reopened.push(to: f.transport("A"))
        #expect(try reopened.pendingOperations().isEmpty)
        #expect(try f.a.baseline().captures.first?.seenCount == 1)
    }

    @Test func extractionQualityRequiresVersionFourAndCapabilityBeforeApply() async throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        var capture = SharedCapture(
            source: CaptureSource(kind: .link, url: "https://example.invalid"))
        capture.generated = GeneratedContent(body: "Login wall", bodyIsThin: true)
        let operation = SyncOperation(
            deviceID: f.device, sequence: 1, captureID: capture.id, baseRevision: 0,
            mutation: .create(capture))
        for version in [1, 2, 3] {
            #expect(
                try f.failure(f.handler.handle(f.request(.apply(operation), version: version)))
                    == .unsupportedVersion)
            #expect(f.resolutions.value == 0)
        }
        let omitQuality: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse = { request in
            let actual = f.handler.handle(request)
            let reply = try SyncDatabase.decode(SyncHTTPReply.self, actual.body)
            return SyncHTTPResponse(
                status: actual.status, headers: actual.headers,
                body: try SyncDatabase.encode(
                    SyncHTTPReply(
                        version: reply.version, principal: reply.principal, result: reply.result,
                        metadataContractVersion: reply.metadataContractVersion,
                        generatedProcessingContractVersion: reply.generatedProcessingContractVersion
                    )))
        }
        let missingQuality = f.transport("A", executor: omitQuality)
        await #expect(throws: SyncHTTPError.unsupportedVersion) {
            try await QualityWire(execute: omitQuality, binding: f.binding, deviceID: f.device)
                .importBaseline(credential: { "A" }, requiringExtractionQualityContract: true)
        }
        #expect(throws: SyncHTTPError.unsupportedVersion) {
            try missingQuality.request(.apply(operation))
        }
        let client = try f.client("quality")
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        let bytes = try client.pendingOperations()
        await #expect(throws: SyncHTTPError.unsupportedVersion) {
            try await client.push(
                to: QualityWire(execute: omitQuality, binding: f.binding, deviceID: f.device),
                credential: { "A" })
        }
        #expect(try client.pendingOperations() == bytes)
        #expect(try f.a.baseline().captures.isEmpty)
        try client.push(to: f.transport("A"))
        #expect(try f.a.baseline().captures.first?.generated.bodyIsThin == true)
        try client.enqueue(
            captureID: capture.id,
            mutation: .edit(CaptureEdit(generatedPatch: GeneratedContentPatch(bodyIsThin: false))))
        try await client.push(
            to: RetainedImageWire(binding: f.binding, deviceID: f.device, handler: f.handler),
            credential: { "A" })
        #expect(try f.a.baseline().captures.first?.generated.bodyIsThin == false)
    }

    @Test func missingQualityReceiptCapabilityKeepsExactOperationForRetry() async throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("quality-receipt")
        var capture = SharedCapture(source: CaptureSource(kind: .link))
        capture.generated = GeneratedContent(body: "Paywall", bodyIsThin: true)
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        let pending = try client.pendingOperations()
        let omitReceiptQuality: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse = {
            request in
            let actual = f.handler.handle(request)
            let reply = try SyncDatabase.decode(SyncHTTPReply.self, actual.body)
            guard case .receipt = reply.result else { return actual }
            return SyncHTTPResponse(
                status: actual.status, headers: actual.headers,
                body: try SyncDatabase.encode(
                    SyncHTTPReply(
                        version: reply.version, principal: reply.principal, result: reply.result,
                        metadataContractVersion: reply.metadataContractVersion,
                        generatedProcessingContractVersion: reply.generatedProcessingContractVersion
                    )))
        }
        #expect(throws: SyncHTTPError.unsupportedVersion) {
            try client.push(to: f.transport("A", executor: omitReceiptQuality))
        }
        #expect(try client.pendingOperations() == pending)
        await #expect(throws: SyncHTTPError.unsupportedVersion) {
            try await client.push(
                to: QualityWire(
                    execute: omitReceiptQuality, binding: f.binding, deviceID: f.device),
                credential: { "A" })
        }
        #expect(try client.pendingOperations() == pending)
        try client.push(to: f.transport("A"))
        #expect(try client.pendingOperations().isEmpty)
        #expect(try f.a.baseline().captures.first?.seenCount == 1)
    }
    @Test func representableReceiptCannotPublishAnOversizedSingleFeedChange() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        var capture = SharedCapture(source: CaptureSource(kind: .text, selection: "feed bound"))
        capture.generated.body = ""
        let createID = UUID()
        let edit = SyncOperation(
            deviceID: f.device, sequence: 2, captureID: capture.id, baseRevision: 1,
            mutation: .edit(CaptureEdit(rating: 4)))
        var projected = capture
        projected.revision = 2
        projected.noteOperationID = createID
        projected.rating = 4
        let principal = SyncPrincipal(
            serviceID: f.service, libraryID: f.libraryA, deviceID: f.device)
        func encoded(_ result: SyncHTTPResult) throws -> Data {
            try SyncDatabase.encode(
                SyncHTTPReply(
                    version: 1, principal: principal, result: result,
                    metadataContractVersion: 1, generatedProcessingContractVersion: 1))
        }
        let overhead = try encoded(
            .receipt(SyncReceipt(operationID: edit.id, outcome: .accepted, capture: projected))
        ).count
        let body = String(repeating: "b", count: SyncHTTPHandler.maximumBodyBytes - overhead)
        capture.generated.body = body
        projected.generated.body = body
        #expect(
            try encoded(
                .receipt(SyncReceipt(operationID: edit.id, outcome: .accepted, capture: projected))
            ).count == SyncHTTPHandler.maximumBodyBytes)
        #expect(
            try encoded(
                .page(
                    FeedPage(
                        cursor: 2,
                        changes: [
                            FeedChange(
                                cursor: 2, operationID: edit.id, deviceID: f.device, sequence: 2,
                                requestedCaptureID: capture.id, capture: projected)
                        ]))
            ).count > SyncHTTPHandler.maximumBodyBytes)
        try f.a.apply(
            SyncOperation(
                id: createID, deviceID: f.device, sequence: 1, captureID: capture.id,
                baseRevision: 0, mutation: .create(capture)))
        let before = try f.a.baseline()
        #expect(throws: SyncHTTPError.resourceLimit) { try f.transport("A").apply(edit) }
        #expect(try f.a.baseline() == before)
        #expect(try f.a.changes(after: 1).changes.isEmpty)
    }

    @Test func oversizedReceiptRollsBackAndDoesNotConsumeOperationSequence() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("size")
        var capture = SharedCapture(source: CaptureSource(kind: .text, selection: "bounded edit"))
        capture.generated.body = String(repeating: "b", count: 9_000_000)
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        try client.push(to: f.transport("A"))
        let baseline = try f.a.baseline()
        let local = try client.captures()
        let edit = CaptureEdit(
            generatedPatch: GeneratedContentPatch(
                ocrText: .set(String(repeating: "o", count: 9_000_000))))
        #expect(throws: SyncHTTPError.resourceLimit) {
            try client.enqueue(captureID: capture.id, mutation: .edit(edit))
        }
        let localUnchanged = try client.captures() == local
        #expect(localUnchanged)
        let pendingCount = try client.pendingOperations().count
        #expect(pendingCount == 0)
        let smaller = try client.enqueue(
            captureID: capture.id, mutation: .edit(CaptureEdit(rating: 4)))
        #expect(smaller.sequence == 2)
        let operation = SyncOperation(
            id: smaller.id, deviceID: smaller.deviceID, sequence: smaller.sequence,
            captureID: smaller.captureID, baseRevision: smaller.baseRevision,
            predecessorID: smaller.predecessorID, mutation: .edit(edit))
        for _ in 0..<2 {
            #expect(throws: SyncHTTPError.resourceLimit) { try f.transport("A").apply(operation) }
            #expect(try client.pendingOperations() == [smaller])
            let authorityUnchanged = try f.a.baseline() == baseline
            #expect(authorityUnchanged)
            #expect(try f.a.changes(after: baseline.cursor).changes.isEmpty)
        }
        #expect(try client.push(to: f.transport("A")).first?.outcome == .accepted)
        #expect(try client.pendingOperations().isEmpty)
        #expect(try f.a.baseline().deviceSequences[f.device] == 2)
        #expect(try f.a.baseline().captures.first?.rating == 4)
    }

    @Test(arguments: [false, true])
    func deletedImageBaselineCachesAssetBeforeOptimisticRestore(asynchronously: Bool) async throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let bytes = Data("retained deleted image".utf8)
        let blob = BlobReference(data: bytes)
        try f.a.upload(blob, offset: 0, chunk: bytes, final: true)
        let remote = UUID()
        let capture = SharedCapture(
            source: CaptureSource(kind: .image, contentHash: blob.digest, blob: blob))
        try f.a.apply(
            SyncOperation(
                deviceID: remote, sequence: 1, captureID: capture.id, baseRevision: 0,
                mutation: .create(capture)))
        try f.a.apply(
            SyncOperation(
                deviceID: remote, sequence: 2, captureID: capture.id, baseRevision: 1,
                mutation: .delete))
        try f.a.expireFeed(through: f.a.baseline().cursor)
        let client = try f.client("restore")
        if asynchronously {
            let wire = RetainedImageWire(binding: f.binding, deviceID: f.device, handler: f.handler)
            try await client.pull(from: wire, credential: { "A" })
            #expect(try client.blobs.read(blob) == bytes)
            try client.enqueue(captureID: capture.id, mutation: .restore)
            #expect(try client.captures().first?.deleted == false)
            try await client.push(to: wire, credential: { "A" })
        } else {
            try client.pull(from: f.transport("A"))
            #expect(try client.blobs.read(blob) == bytes)
            try client.enqueue(captureID: capture.id, mutation: .restore)
            #expect(try client.captures().first?.deleted == false)
            try client.push(to: f.transport("A"))
        }
        #expect(try f.a.baseline().captures.first?.deleted == false)
    }

    @Test func processingRequiresVersionThreeBeforeStorageAndSynchronousProbeKeepsV2Compatible()
        throws
    {
        let f = try HTTPFixture()
        defer { f.clean() }
        var capture = SharedCapture(
            source: CaptureSource(kind: .text, selection: "Processing version contract"))
        capture.generated = GeneratedContent(
            taggingProcessed: true, taggingInputFingerprint: "exact-input")
        let operation = SyncOperation(
            deviceID: f.device, sequence: 1, captureID: capture.id, baseRevision: 0,
            mutation: .create(capture))
        for version in [1, 2] {
            let refused = f.handler.handle(try f.request(.apply(operation), version: version))
            #expect(try f.failure(refused) == .unsupportedVersion)
            #expect(f.resolutions.value == 0)
        }
        let missingProcessing = f.transport(
            "A",
            executor: { request in
                let actual = f.handler.handle(request)
                let reply = try SyncDatabase.decode(SyncHTTPReply.self, actual.body)
                return SyncHTTPResponse(
                    status: actual.status, headers: actual.headers,
                    body: try SyncDatabase.encode(
                        SyncHTTPReply(
                            version: reply.version, principal: reply.principal,
                            result: reply.result,
                            metadataContractVersion: reply.metadataContractVersion)))
            })
        #expect(throws: SyncHTTPError.unsupportedVersion) {
            try missingProcessing.request(.apply(operation))
        }
        #expect(try f.a.baseline().captures.isEmpty)
        let accepted = f.handler.handle(try f.request(.apply(operation), version: 3))
        #expect(accepted.status == 200)
        let reply = try SyncDatabase.decode(SyncHTTPReply.self, accepted.body)
        #expect(reply.metadataContractVersion == 1)
        #expect(reply.generatedProcessingContractVersion == 1)
        let descriptor = SyncOperation(
            deviceID: f.device, sequence: 2, captureID: capture.id, baseRevision: 1,
            mutation: .edit(
                CaptureEdit(generatedPatch: GeneratedContentPatch(taggingProcessing: .pending))))
        let replacement = SyncOperation(
            deviceID: f.device, sequence: 2, captureID: capture.id, baseRevision: 1,
            mutation: .edit(CaptureEdit(generated: GeneratedContent(taggingProcessed: false))))
        let before = f.resolutions.value
        for newOperation in [descriptor, replacement] {
            #expect(
                try f.failure(f.handler.handle(f.request(.apply(newOperation), version: 2)))
                    == .unsupportedVersion)
            #expect(throws: SyncHTTPError.unsupportedVersion) {
                try missingProcessing.apply(newOperation)
            }
        }
        #expect(f.resolutions.value == before + 2)
        #expect(try f.a.baseline().captures.first?.generated.taggingProcessed == true)
        let v2Operation = SyncOperation(
            deviceID: f.device, sequence: 2, captureID: capture.id, baseRevision: 1,
            mutation: .edit(
                CaptureEdit(generatedPatch: GeneratedContentPatch(body: .set("v2 body")))))
        try missingProcessing.apply(v2Operation)
        #expect(try f.a.baseline().captures.first?.generated.body == "v2 body")
        #expect(
            try f.a.baseline().captures.first?.generated.taggingInputFingerprint == "exact-input")
    }

    @Test func handlerRequiresVersionTwoForNewSemanticsBeforeResolvingStorage() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let capture = SharedCapture(
            source: CaptureSource(kind: .text, selection: "Synthetic metadata"),
            metadata: CaptureMetadata(sourceAppBundleID: "test.original"))
        let operation = SyncOperation(
            deviceID: f.device, sequence: 1, captureID: capture.id,
            baseRevision: 0, mutation: .create(capture))
        let rejected = f.handler.handle(try f.request(.apply(operation)))
        #expect(try f.failure(rejected) == .unsupportedVersion)
        #expect(f.resolutions.value == 0)
        #expect(try f.a.baseline().captures.isEmpty)
        let accepted = f.handler.handle(try f.request(.apply(operation), version: 2))
        #expect(accepted.status == 200)
        #expect(try f.a.baseline().captures.first?.metadata == capture.metadata)
    }

    @Test func synchronousMetadataGuardAlsoProtectsDirectRequestAndKeepsLegacyCompatible() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let calls = Counter()
        let transport = f.transport(
            "A",
            executor: { request in
                calls.increment()
                let actual = f.handler.handle(request)
                let reply = try SyncDatabase.decode(SyncHTTPReply.self, actual.body)
                return SyncHTTPResponse(
                    status: actual.status, headers: actual.headers,
                    body: try SyncDatabase.encode(
                        SyncHTTPReply(
                            version: reply.version, principal: reply.principal,
                            result: reply.result)))
            })
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "Legacy"))
        try transport.apply(
            SyncOperation(
                deviceID: f.device, sequence: 1, captureID: capture.id,
                baseRevision: 0, mutation: .create(capture)))
        #expect(calls.value == 1)
        let edits = [
            CaptureEdit(metadata: CaptureMetadataPatch(reminder: .clear)),
            CaptureEdit(sourceContent: SourceContentPatch(title: "Original title")),
            CaptureEdit(generatedPatch: GeneratedContentPatch(body: .clear)),
        ]
        for edit in edits {
            let operation = SyncOperation(
                deviceID: f.device, sequence: 2, captureID: capture.id,
                baseRevision: 1, mutation: .edit(edit))
            #expect(throws: SyncHTTPError.unsupportedVersion) {
                try transport.request(.apply(operation))
            }
            #expect(try f.a.baseline().captures.first?.revision == 1)
        }
        #expect(calls.value == 4)
    }

    @Test("Authentication gates all operations before decoding or looking up library storage")
    func authenticationGate() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let blob = BlobReference(data: Data("private".utf8))
        let actions: [SyncHTTPAction] = [
            .baseline, .changes(cursor: 0, limit: 1), .download(blob),
            .upload(blob, offset: 0, chunk: Data(), final: true), .apply(f.operation("A")),
        ]
        for action in actions {
            for headers in [
                [:], ["Authorization": "Bearer revoked"], ["Authorization": "Bearer  A"],
                ["Authorization": "Bearer A", "authorization": "Bearer B"],
            ] {
                let response = f.handler.handle(try f.request(action, headers: headers))
                #expect(response.status == 401)
                #expect(try f.failure(response) == .unauthorized)
            }
        }
        f.auth.revoke("A")
        #expect(f.handler.handle(try f.request(.baseline)).status == 401)
        #expect(
            f.handler.handle(
                SyncHTTPRequest(
                    method: "POST", path: "/v1/sync", headers: [:], body: Data("bad JSON".utf8))
            ).status == 401)
        #expect(f.resolutions.value == 0)
        #expect(try f.a.baseline().captures.isEmpty)
        #expect(try f.b.baseline().captures.isEmpty)
    }

    @Test("Authenticated library and device assertions reject spoofing before lookup or mutation")
    func identityAssertions() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let op = f.operation("A")
        let mismatched = try f.request(.apply(op), token: "B", library: f.libraryA)
        #expect(f.handler.handle(mismatched).status == 403)
        let deviceMismatch = try f.request(.baseline, device: UUID())
        #expect(f.handler.handle(deviceMismatch).status == 403)
        let forged = SyncOperation(
            deviceID: UUID(), sequence: 1, captureID: op.captureID, baseRevision: 0,
            mutation: op.mutation)
        #expect(f.handler.handle(try f.request(.apply(forged))).status == 403)
        let wrongService = SyncHTTPHandler(
            serviceID: UUID(), authorizer: f.auth, server: { _ in f.a })
        #expect(wrongService.handle(try f.request(.apply(op))).status == 403)
        let wrongAssertion = SyncHTTPEnvelope(
            expectedServiceID: UUID(), expectedLibraryID: f.libraryA, expectedDeviceID: f.device,
            action: .apply(op))
        #expect(
            f.handler.handle(
                SyncHTTPRequest(
                    method: "POST", path: "/v1/sync",
                    headers: ["Authorization": "Bearer A", "Content-Type": "application/json"],
                    body: try SyncDatabase.encode(wrongAssertion))
            ).status == 403)
        #expect(f.resolutions.value == 0)
        #expect(try f.a.baseline().captures.isEmpty)
        #expect(try f.b.baseline().captures.isEmpty)
        let wrongProvider = SyncHTTPHandler(
            serviceID: f.service, authorizer: f.auth, server: { _ in f.a })
        #expect(
            wrongProvider.handle(try f.request(.baseline, token: "B", library: f.libraryB)).status
                == 503)
    }

    @Test(
        "Colliding capture, operation and device IDs stay isolated across receipts, feeds and blob bytes"
    )
    func librariesAreIsolated() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let a = f.transport("A")
        let b = f.transport("B")
        let captureID = UUID()
        let operationID = UUID()
        let bytesA = Data("library A bytes".utf8)
        let bytesB = Data("library B bytes".utf8)
        let blobA = BlobReference(data: bytesA)
        let blobB = BlobReference(data: bytesB)
        try a.upload(blobA, offset: 0, chunk: bytesA, final: true)
        try b.upload(blobB, offset: 0, chunk: bytesB, final: true)
        func operation(_ blob: BlobReference, _ note: String) -> SyncOperation {
            SyncOperation(
                id: operationID, deviceID: f.device, sequence: 1, captureID: captureID,
                baseRevision: 0,
                mutation: .create(
                    SharedCapture(
                        id: captureID, source: CaptureSource(kind: .image, blob: blob), note: note))
            )
        }
        let opA = operation(blobA, "A")
        let opB = operation(blobB, "B")
        let receiptA = try a.apply(opA)
        let receiptB = try b.apply(opB)
        #expect(try a.apply(opA) == receiptA)
        #expect(try b.apply(opB) == receiptB)
        #expect(try a.baseline().captures.first?.note == "A")
        #expect(try b.baseline().captures.first?.note == "B")
        #expect(try a.changes(after: 0, limit: 100).changes.count == 1)
        #expect(try b.changes(after: 0, limit: 100).changes.count == 1)
        #expect(try a.download(blobA) == bytesA)
        #expect(try b.download(blobB) == bytesB)
        #expect(throws: SyncError.blobMissing) { try b.download(blobA) }
        #expect(throws: SyncError.blobMissing) { try a.download(blobB) }
        #expect(try a.baseline().deviceSequences[f.device] == 1)
        #expect(try b.baseline().deviceSequences[f.device] == 1)
    }

    @Test(
        "Client executor roundtrip preserves exact queued identity after a committed response is lost"
    )
    func durableRoundtrip() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("client")
        let bytes = Data("roundtrip image".utf8)
        let blob = try client.blobs.put(bytes)
        let capture = SharedCapture(source: CaptureSource(kind: .image, blob: blob), note: "local")
        let operation = try client.enqueue(captureID: capture.id, mutation: .create(capture))
        let lost = Counter()
        let transport = f.transport(
            "A",
            executor: { request in
                let response = f.handler.handle(request)
                if let envelope = try? SyncDatabase.decode(SyncHTTPEnvelope.self, request.body),
                    case .apply = envelope.action, lost.increment() == 1
                {
                    throw SyncError.acknowledgementLost
                }
                return response
            })
        #expect(throws: SyncError.acknowledgementLost) { try client.push(to: transport) }
        #expect(try client.pendingOperations() == [operation])
        let reopened = try f.client("client")
        #expect(try reopened.pendingOperations() == [operation])
        try reopened.pull(from: transport)
        #expect(try reopened.captures().first?.seenCount == 1)
        try reopened.push(to: transport)
        #expect(try reopened.pendingOperations().isEmpty)
        #expect(try f.a.changes(after: 0).changes.count == 1)
        let peer = try f.client("peer")
        try f.a.expireFeed(through: f.a.baseline().cursor)
        try peer.pull(from: transport)
        #expect(try peer.captures().first?.id == capture.id)
        #expect(try peer.blobs.read(blob) == bytes)
    }

    @Test("Binding mismatch and omitted bindings preserve queued data, cursor and blobs")
    func clientBinding() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("bound")
        let blob = try client.blobs.put(Data("retained".utf8))
        let capture = SharedCapture(source: CaptureSource(kind: .image, blob: blob))
        let op = try client.enqueue(captureID: capture.id, mutation: .create(capture))
        let different = SyncLibraryBinding(libraryID: f.libraryB, serviceID: f.service)
        #expect(throws: SyncBindingError.mismatch) { try f.client("bound", binding: different) }
        #expect(throws: SyncBindingError.mismatch) { try f.client("bound", binding: nil) }
        #expect(throws: SyncBindingError.mismatch) { try client.push(to: f.b) }
        #expect(throws: SyncBindingError.mismatch) { try client.push(to: f.transport("B")) }
        let wrongService = SyncLibraryBinding(libraryID: f.libraryA, serviceID: UUID())
        #expect(throws: SyncBindingError.mismatch) { try f.client("bound", binding: wrongService) }
        let reopened = try f.client("bound")
        #expect(try reopened.pendingOperations() == [op])
        #expect(try reopened.cursor() == 0)
        #expect(try reopened.blobs.read(blob) == Data("retained".utf8))
        #expect(throws: SyncHTTPError.forbidden) {
            try reopened.push(to: f.transport("A", credential: "B"))
        }
        #expect(try reopened.pendingOperations() == [op])
        #expect(try f.b.baseline().captures.isEmpty)
    }

    @Test(
        "Production enrollment refuses previously used unbound clients even after acknowledged work drains"
    )
    func legacyEnrollment() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let legacy = try f.client("legacy", binding: nil)
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "legacy"))
        try legacy.enqueue(captureID: capture.id, mutation: .create(capture))
        #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) { try f.client("legacy") }
        #expect(throws: SyncBindingError.mismatch) { try legacy.push(to: f.transport("A")) }
        try legacy.push(to: f.a)
        #expect(try legacy.pendingOperations().isEmpty)
        #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) { try f.client("legacy") }
        #expect(try f.client("legacy", binding: nil).captures().first?.id == capture.id)
        let blobsOnly = try f.client("blobsOnly", binding: nil)
        _ = try blobsOnly.blobs.put(Data("legacy asset".utf8))
        #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
            try f.client("blobsOnly")
        }
    }

    @Test(
        "Server DB and blob root cannot be accidentally reassigned or opened without their binding")
    func serverStorageOwnership() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        #expect(throws: SyncBindingError.mismatch) {
            try SyncServer(
                databaseURL: f.root.appendingPathComponent("a.sqlite"),
                blobDirectory: f.root.appendingPathComponent("a-blobs"), libraryID: f.libraryB,
                serviceID: f.service)
        }
        #expect(throws: SyncBindingError.mismatch) {
            try SyncServer(
                databaseURL: f.root.appendingPathComponent("a.sqlite"),
                blobDirectory: f.root.appendingPathComponent("a-blobs"))
        }
        #expect(throws: SyncBindingError.mismatch) {
            try SyncServer(
                databaseURL: f.root.appendingPathComponent("aliased.sqlite"),
                blobDirectory: f.root.appendingPathComponent("a-blobs"), libraryID: f.libraryB,
                serviceID: f.service)
        }
        #expect(throws: SyncBindingError.mismatch) {
            try BlobStore(directory: f.root.appendingPathComponent("a-blobs"))
        }
        #expect(throws: SyncBindingError.mismatch) {
            try SyncServer(
                databaseURL: f.root.appendingPathComponent("wrong-service.sqlite"),
                blobDirectory: f.root.appendingPathComponent("a-blobs"), libraryID: f.libraryA,
                serviceID: UUID())
        }
        let reopened = try SyncServer(
            databaseURL: f.root.appendingPathComponent("a.sqlite"),
            blobDirectory: f.root.appendingPathComponent("a-blobs"), libraryID: f.libraryA,
            serviceID: f.service)
        #expect(reopened.libraryID == f.libraryA)
    }

    @Test("Already-open unbound handles cannot access a database enrolled by another handle")
    func staleHandles() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let stale = try f.client("stale", binding: nil)
        let enrolled = try f.client("stale")
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "stale local"))
        #expect(throws: SyncBindingError.mismatch) {
            try stale.enqueue(captureID: capture.id, mutation: .create(capture))
        }
        #expect(throws: SyncBindingError.mismatch) { try stale.captures() }
        #expect(throws: SyncBindingError.mismatch) { try stale.push(to: f.a) }
        #expect(throws: SyncBindingError.mismatch) { try stale.pull(from: f.a) }
        #expect(try enrolled.pendingOperations().isEmpty)
        #expect(try enrolled.cursor() == 0)
        let db = f.root.appendingPathComponent("stale-server.sqlite")
        let dir = f.root.appendingPathComponent("stale-server-blobs")
        let oldServer = try SyncServer(databaseURL: db, blobDirectory: dir)
        let oldReader = oldServer.reader
        let enrolledServer = try SyncServer(
            databaseURL: db, blobDirectory: dir, libraryID: f.libraryA, serviceID: f.service)
        #expect(throws: SyncBindingError.mismatch) {
            try oldServer.apply(f.operation("stale server"))
        }
        #expect(throws: SyncBindingError.mismatch) { try oldServer.baseline() }
        #expect(throws: SyncBindingError.mismatch) { try oldReader.acceptedCaptures() }
        let bytes = Data("stale upload".utf8)
        #expect(throws: SyncBindingError.mismatch) {
            try oldServer.upload(BlobReference(data: bytes), offset: 0, chunk: bytes, final: true)
        }
        #expect(try enrolledServer.baseline().captures.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["library-owner"])
    }

    @Test("Routing, decoding, version, page and upload bounds reject without storage access")
    func requestBounds() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let valid = try f.request(.baseline)
        let cases: [(SyncHTTPRequest, Int, SyncHTTPError)] = [
            (
                SyncHTTPRequest(
                    method: "GET", path: valid.path, headers: valid.headers, body: valid.body), 405,
                .methodNotAllowed
            ),
            (
                SyncHTTPRequest(
                    method: "POST", path: "/fixtureSync", headers: valid.headers, body: valid.body),
                404, .notFound
            ),
            (
                SyncHTTPRequest(
                    method: "POST", path: valid.path, headers: valid.headers,
                    body: Data(repeating: 0, count: SyncHTTPHandler.maximumBodyBytes + 1)), 413,
                .requestTooLarge
            ),
            (
                SyncHTTPRequest(
                    method: "POST", path: valid.path,
                    headers: ["Authorization": "Bearer A", "Content-Type": "text/plain"],
                    body: valid.body), 415, .unsupportedMediaType
            ),
            (
                SyncHTTPRequest(
                    method: "POST", path: valid.path, headers: valid.headers,
                    body: Data("bad A secret payload".utf8)), 400, .malformedRequest
            ),
            (try f.request(.baseline, version: 5), 400, .unsupportedVersion),
            (
                try f.request(
                    .upload(
                        BlobReference(data: Data()), offset: 0,
                        chunk: Data(repeating: 0, count: 65_537), final: false)), 413,
                .requestTooLarge
            ),
        ]
        for (request, status, error) in cases {
            let response = f.handler.handle(request)
            #expect(response.status == status)
            #expect(try f.failure(response) == error)
            #expect(response.headers["Content-Type"] == "application/json")
            #expect(!String(decoding: response.body, as: UTF8.self).contains("secret payload"))
        }
        let page = f.handler.handle(try f.request(.changes(cursor: 0, limit: 1001)))
        #expect(page.status == 422)
        #expect(f.resolutions.value == 0)
        let gap = SyncOperation(
            deviceID: f.device, sequence: 2, captureID: UUID(), baseRevision: 0, mutation: .delete)
        #expect(throws: SyncError.outOfOrder(expected: 1)) { try f.transport("A").apply(gap) }
    }

    @Test func feedStopsBeforeMaterializingAnOversizedTailAndDoesNotSkipIt() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let operation = f.operation("small first change")
        _ = try f.a.apply(operation)
        let writer = try SyncDatabase.open(at: f.root.appendingPathComponent("a.sqlite"))
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO sync_feed (cursor, payload) VALUES (2, zeroblob(?))",
                arguments: [SyncHTTPHandler.maximumBodyBytes + 1])
            try db.execute(sql: "UPDATE sync_meta SET cursor=2")
        }
        let response = f.handler.handle(try f.request(.changes(cursor: 0, limit: 1000)))
        #expect(response.status == 200)
        let reply = try SyncDatabase.decode(SyncHTTPReply.self, response.body)
        guard case .page(let page) = reply.result else {
            Issue.record("Expected a bounded feed page")
            return
        }
        #expect(page.cursor == 1)
        #expect(page.changes.map(\.operationID) == [operation.id])
        for _ in 0..<2 {
            let refused = f.handler.handle(try f.request(.changes(cursor: page.cursor, limit: 1)))
            #expect(refused.status == 503)
            #expect(try f.failure(refused) == .resourceLimit)
        }
        #expect(try f.a.baseline().cursor == 2)
    }

    @Test func feedBudgetUsesTheExactHTTPEnvelopeAndIncludesAnExactFit() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let device = UUID()
        var capture = SharedCapture(source: CaptureSource(kind: .text, selection: ""))
        capture.revision = 1
        let operationID = UUID()
        func change() -> FeedChange {
            FeedChange(
                cursor: 1, operationID: operationID, deviceID: device, sequence: 1,
                requestedCaptureID: capture.id, capture: capture)
        }
        let principal = SyncPrincipal(
            serviceID: f.service, libraryID: f.libraryA, deviceID: f.device)
        let overhead = try SyncDatabase.encode(
            SyncHTTPReply(
                version: 1, principal: principal,
                result: .page(FeedPage(cursor: 1, changes: [change()])),
                metadataContractVersion: 1, generatedProcessingContractVersion: 1,
                extractionQualityContractVersion: 1)
        ).count
        capture.source.selection = String(
            repeating: "x", count: SyncHTTPHandler.maximumBodyBytes - overhead)
        let writer = try SyncDatabase.open(at: f.root.appendingPathComponent("a.sqlite"))
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO sync_feed (cursor, payload) VALUES (1, ?)",
                arguments: [try SyncDatabase.encode(change())])
            try db.execute(sql: "UPDATE sync_meta SET cursor=1")
        }
        let response = f.handler.handle(try f.request(.changes(cursor: 0, limit: 1000)))
        #expect(response.status == 200)
        #expect(response.body.count == SyncHTTPHandler.maximumBodyBytes)
        capture.source.selection?.append("x")
        try writer.write { db in
            try db.execute(
                sql: "UPDATE sync_feed SET payload=? WHERE cursor=1",
                arguments: [try SyncDatabase.encode(change())])
        }
        let refused = f.handler.handle(try f.request(.changes(cursor: 0, limit: 1)))
        #expect(try f.failure(refused) == .resourceLimit)
    }

    @Test func feedBudgetCountsSeparatorsAndContinuesAtTheLastIncludedChange() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        var changes: [FeedChange] = []
        for sequence in 1...3 {
            let capture = SharedCapture(source: CaptureSource(kind: .text, selection: "same size"))
            _ = try f.a.apply(
                SyncOperation(
                    deviceID: f.device, sequence: Int64(sequence), captureID: capture.id,
                    baseRevision: 0, mutation: .create(capture)))
            changes.append(
                contentsOf: try f.a.changes(after: Int64(sequence - 1), limit: 1).changes)
        }
        let payloadBytes = try changes.prefix(2).reduce(0) {
            $0 + (try SyncDatabase.encode($1).count)
        }
        let overhead = SyncHTTPHandler.maximumBodyBytes - payloadBytes - 1
        let page = try f.a.changes(after: 0, limit: 1000) { _ in overhead }
        #expect(page.cursor == 2)
        #expect(page.changes == Array(changes.prefix(2)))
        let next = try f.a.changes(after: page.cursor, limit: 1000) { _ in overhead }
        #expect(next.changes == [changes[2]])
        #expect(next.cursor == 3)
        let empty = try f.a.changes(after: next.cursor, limit: 1000) { _ in overhead }
        #expect(empty.cursor == 3)
        #expect(empty.changes.isEmpty)
    }

    @Test func baselineRequestsRefuseOversizedRowsBeforeDecodingAndPreservePageCompleteness() throws
    {
        let f = try HTTPFixture()
        defer { f.clean() }
        let first = SharedCapture(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            source: CaptureSource(kind: .text, selection: "small first record"))
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let writer = try SyncDatabase.open(at: f.root.appendingPathComponent("a.sqlite"))
        try writer.write { db in
            try SyncDatabase.save(db, first)
            try db.execute(
                sql: "INSERT INTO sync_records (id, payload) VALUES (?, zeroblob(?))",
                arguments: [second.uuidString, SyncHTTPHandler.maximumBodyBytes + 1])
            try db.execute(sql: "UPDATE sync_meta SET cursor=2")
        }
        for action in [
            SyncHTTPAction.baseline, .baselinePage(after: nil, limit: 1000, expectedCursor: 2),
        ] {
            let refused = f.handler.handle(try f.request(action))
            #expect(refused.status == 503)
            #expect(try f.failure(refused) == .resourceLimit)
        }
        let response = f.handler.handle(
            try f.request(.baselinePage(after: nil, limit: 1, expectedCursor: 2)))
        let reply = try SyncDatabase.decode(SyncHTTPReply.self, response.body)
        guard case .baseline(let page) = reply.result else {
            Issue.record("Expected a complete requested baseline page")
            return
        }
        #expect(page.captures == [first])
        #expect(page.cursor == 2)
        for _ in 0..<2 {
            let refused = f.handler.handle(
                try f.request(.baselinePage(after: first.id, limit: 1, expectedCursor: 2)))
            #expect(try f.failure(refused) == .resourceLimit)
        }
        let summary = f.handler.handle(
            try f.request(.baselinePage(after: nil, limit: 0, expectedCursor: 2)))
        #expect(summary.status == 200)
    }

    @Test func baselineBudgetIncludesDeviceSequencesAndTheExactHTTPEnvelope() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        var capture = SharedCapture(source: CaptureSource(kind: .text, selection: ""))
        let sequences = [UUID(): Int64(9), UUID(): Int64(10)]
        let principal = SyncPrincipal(
            serviceID: f.service, libraryID: f.libraryA, deviceID: f.device)
        let overhead = try SyncDatabase.encode(
            SyncHTTPReply(
                version: 1, principal: principal,
                result: .baseline(
                    Baseline(cursor: 10, captures: [capture], deviceSequences: sequences)),
                metadataContractVersion: 1, generatedProcessingContractVersion: 1,
                extractionQualityContractVersion: 1)
        ).count
        capture.source.selection = String(
            repeating: "x", count: SyncHTTPHandler.maximumBodyBytes - overhead)
        let writer = try SyncDatabase.open(at: f.root.appendingPathComponent("a.sqlite"))
        try writer.write { db in
            try SyncDatabase.save(db, capture)
            for (id, sequence) in sequences {
                try db.execute(
                    sql: "INSERT INTO sync_devices (id, sequence) VALUES (?, ?)",
                    arguments: [id.uuidString, sequence])
            }
            try db.execute(sql: "UPDATE sync_meta SET cursor=10")
        }
        for action in [
            SyncHTTPAction.baseline, .baselinePage(after: nil, limit: 1000, expectedCursor: 10),
        ] {
            let response = f.handler.handle(try f.request(action))
            #expect(response.status == 200)
            #expect(response.body.count == SyncHTTPHandler.maximumBodyBytes)
        }
        capture.source.selection?.append("x")
        try writer.write { try SyncDatabase.save($0, capture) }
        let refused = f.handler.handle(
            try f.request(.baselinePage(after: nil, limit: 1, expectedCursor: 10)))
        #expect(try f.failure(refused) == .resourceLimit)
    }

    @Test func baselineDeviceSummaryStopsAtItsByteBudget() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let writer = try SyncDatabase.open(at: f.root.appendingPathComponent("a.sqlite"))
        let sequence = Int64(1)
        let pairBytes = try SyncDatabase.encode([UUID(): sequence]).count - 2
        try writer.write { db in
            for _ in 0..<1000 {
                try db.execute(
                    sql: "INSERT INTO sync_devices (id, sequence) VALUES (?, ?)",
                    arguments: [UUID().uuidString, sequence])
            }
        }
        #expect(throws: SyncHTTPError.resourceLimit) {
            try f.a.boundedBaseline(limit: 0) { _, _ in
                SyncHTTPHandler.maximumBodyBytes - pairBytes
            }
        }
        let summary = try f.a.boundedBaseline(limit: 0) { _, _ in
            SyncHTTPHandler.maximumBodyBytes - (1000 * pairBytes + 999)
        }
        #expect(summary.deviceSequences.count == 1000)
        #expect(summary.captures.isEmpty)
    }

    @Test("Oversized baseline and unexpected storage errors produce bounded generic JSON")
    func responseLimitsAndHygiene() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let huge = SharedCapture(
            source: CaptureSource(
                kind: .text,
                selection: String(repeating: "x", count: SyncHTTPHandler.maximumBodyBytes)))
        try f.a.apply(
            SyncOperation(
                deviceID: f.device, sequence: 1, captureID: huge.id, baseRevision: 0,
                mutation: .create(huge)))
        let limited = f.handler.handle(try f.request(.baseline))
        #expect(limited.status == 503)
        #expect(try f.failure(limited) == .resourceLimit)
        struct PrivateStorageError: Error {}
        let failing = SyncHTTPHandler(
            serviceID: f.service, authorizer: f.auth, server: { _ in throw PrivateStorageError() })
        let generic = failing.handle(try f.request(.baseline))
        #expect(try f.failure(generic) == .unavailable)
        #expect(generic.body.count < 200)
        #expect(!String(decoding: generic.body, as: UTF8.self).contains("PrivateStorageError"))
    }

    @Test("Client rejects mismatched successful response scope before acknowledging queued work")
    func responseScope() throws {
        let f = try HTTPFixture()
        defer { f.clean() }
        let client = try f.client("scope")
        let op = f.operation("scope")
        try client.enqueue(captureID: op.captureID, mutation: op.mutation)
        let transport = f.transport(
            "A",
            executor: { request in
                let actual = f.handler.handle(request)
                let reply = try SyncDatabase.decode(SyncHTTPReply.self, actual.body)
                return SyncHTTPResponse(
                    status: 200, headers: actual.headers,
                    body: try SyncDatabase.encode(
                        SyncHTTPReply(
                            version: 1,
                            principal: SyncPrincipal(
                                serviceID: f.service, libraryID: f.libraryB, deviceID: f.device),
                            result: reply.result)))
            })
        #expect(throws: SyncHTTPError.invalidResponse) { try client.push(to: transport) }
        #expect(try client.pendingOperations().count == 1)
        try client.push(to: f.transport("A"))
        #expect(try f.a.baseline().captures.first?.seenCount == 1)
    }
}

private struct QualityWire: AsyncSyncTransport {
    let execute: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse
    let binding: SyncLibraryBinding
    let deviceID: UUID
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse { try execute(request) }
}

private struct IncompleteBaselineTransport: BoundSyncTransport {
    let backing: SyncHTTPTransport
    let snapshot: Baseline
    let bytes: Data
    let downloads: Counter
    var binding: SyncLibraryBinding { backing.binding }
    var deviceID: UUID { backing.deviceID }
    func apply(_ operation: SyncOperation) throws -> SyncReceipt { try backing.apply(operation) }
    func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        throw SyncError.cursorExpired
    }
    func baseline() throws -> Baseline { snapshot }
    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try backing.upload(blob, offset: offset, chunk: chunk, final: final)
    }
    func download(_ blob: BlobReference) throws -> Data {
        downloads.increment()
        return bytes
    }
}

private enum InvalidReceipt: String, CaseIterable {
    case acceptedWithoutCapture, noteConflictWithoutCapture, deletedWithoutCapture
    case staleRestoreWithoutCapture, alreadyExistsWithoutCapture
    case wrongIdentity, wrongCreateIdentity, noteConflictWithoutNote, staleRestoreForEdit
    case alreadyExistsForEdit, missingWithCapture, liveDeleted, liveDelete
}

private func syntheticReply(_ result: SyncHTTPResult, principal: SyncPrincipal) throws
    -> SyncHTTPResponse
{
    SyncHTTPResponse(
        status: 200, headers: ["Content-Type": "application/json"],
        body: try SyncDatabase.encode(
            SyncHTTPReply(version: 1, principal: principal, result: result)))
}

private struct RetainedImageWire: AsyncSyncTransport {
    let binding: SyncLibraryBinding
    let deviceID: UUID
    let handler: SyncHTTPHandler
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        handler.handle(request)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class SyntheticAuthorizer: SyncAuthorizer, @unchecked Sendable {
    private let lock = NSLock()
    private var principals: [String: SyncPrincipal]
    init(_ principals: [String: SyncPrincipal]) { self.principals = principals }
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        lock.withLock { principals[bearerCredential] }
    }
    func revoke(_ token: String) { lock.withLock { principals[token] = nil } }
}

private final class HTTPFixture: Sendable {
    let root: URL
    let libraryA = UUID()
    let libraryB = UUID()
    let service = UUID()
    let device = UUID()
    let a: SyncServer
    let b: SyncServer
    let auth: SyntheticAuthorizer
    let resolutions = Counter()
    var binding: SyncLibraryBinding { SyncLibraryBinding(libraryID: libraryA, serviceID: service) }
    var principal: SyncPrincipal {
        SyncPrincipal(serviceID: service, libraryID: libraryA, deviceID: device)
    }
    var handler: SyncHTTPHandler {
        SyncHTTPHandler(
            serviceID: service, authorizer: auth,
            server: { [self] id in
                resolutions.increment()
                return id == libraryA ? a : b
            })
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("capd-http-\(UUID())")
        a = try SyncServer(
            databaseURL: root.appendingPathComponent("a.sqlite"),
            blobDirectory: root.appendingPathComponent("a-blobs"), libraryID: libraryA,
            serviceID: service)
        b = try SyncServer(
            databaseURL: root.appendingPathComponent("b.sqlite"),
            blobDirectory: root.appendingPathComponent("b-blobs"), libraryID: libraryB,
            serviceID: service)
        auth = SyntheticAuthorizer([
            "A": SyncPrincipal(serviceID: service, libraryID: libraryA, deviceID: device),
            "B": SyncPrincipal(serviceID: service, libraryID: libraryB, deviceID: device),
        ])
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func operation(_ note: String) -> SyncOperation {
        let capture = SharedCapture(source: CaptureSource(kind: .text, selection: note))
        return SyncOperation(
            deviceID: device, sequence: 1, captureID: capture.id, baseRevision: 0,
            mutation: .create(capture))
    }
    func request(
        _ action: SyncHTTPAction, token: String = "A", library: UUID? = nil, device: UUID? = nil,
        version: Int = 1, headers: [String: String]? = nil
    ) throws -> SyncHTTPRequest {
        SyncHTTPRequest(
            method: "POST", path: "/v1/sync",
            headers: headers ?? [
                "Content-Type": "application/json", "Authorization": "Bearer \(token)",
            ],
            body: try SyncDatabase.encode(
                SyncHTTPEnvelope(
                    version: version, expectedServiceID: service,
                    expectedLibraryID: library ?? libraryA,
                    expectedDeviceID: device ?? self.device, action: action)))
    }
    func failure(_ response: SyncHTTPResponse) throws -> SyncHTTPError? {
        let reply = try SyncDatabase.decode(SyncHTTPReply.self, response.body)
        guard case .failure(let error) = reply.result else { return nil }
        return error
    }
    func transport(
        _ token: String, credential: String? = nil,
        executor: (@Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse)? = nil
    ) -> SyncHTTPTransport {
        SyncHTTPTransport(
            binding: SyncLibraryBinding(
                libraryID: token == "A" ? libraryA : libraryB, serviceID: service),
            deviceID: device, credential: { credential ?? token },
            execute: executor ?? { [self] in handler.handle($0) })
    }
    func client(_ name: String) throws -> SyncClient { try client(name, binding: binding) }
    func client(_ name: String, binding: SyncLibraryBinding?) throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("\(name).sqlite"),
            blobDirectory: root.appendingPathComponent("\(name)-blobs"), deviceID: device,
            binding: binding)
    }
}
