import Foundation
import GRDB

public struct RejectedWork: Codable, Equatable, Sendable {
    public let operation: SyncOperation
    public let receipt: SyncReceipt
}

public final class SyncClient: Sendable {
    public typealias Projection = @Sendable (Database, SharedCapture) throws -> Void
    public let binding: SyncLibraryBinding?
    public let deviceID: UUID
    public let blobs: BlobStore
    let writer: any DatabaseWriter
    let writerIdentity: ObjectIdentifier
    let projectionGate = ProjectionGate()
    private let project: Projection

    public convenience init(
        databaseURL: URL, blobDirectory: URL, deviceID: UUID? = nil,
        binding: SyncLibraryBinding? = nil
    ) throws {
        let ownsBlobs = try BlobStore.validateExistingOwnership(blobDirectory, binding: binding)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: blobDirectory.path)) ?? []
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            var configuration = Configuration()
            configuration.readonly = true
            let reader = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            let storedBinding = try reader.read {
                try SyncDatabase.checkEnrollment(
                    $0, role: "client", deviceID: deviceID, binding: binding,
                    hasUnboundBlobs: files.contains { $0 != "library-owner" })
            }
            guard storedBinding == nil || ownsBlobs else { throw SyncBindingError.mismatch }
        }
        let writer = try SyncDatabase.open(at: databaseURL)
        try self.init(
            writer: writer,
            blobs: BlobStore(directory: blobDirectory, binding: binding),
            deviceID: deviceID, binding: binding)
    }

    /// The projection participates in each outbox/pull transaction; it must not enqueue writes.
    public init(
        writer: any DatabaseWriter, blobs: BlobStore, deviceID: UUID? = nil,
        binding: SyncLibraryBinding? = nil,
        prepareProjection: @escaping @Sendable (Database) throws -> Void = { _ in },
        project: @escaping Projection = { _, _ in }
    ) throws {
        let hasUnboundBlobs = try FileManager.default.contentsOfDirectory(
            atPath: blobs.directory.path
        )
        .contains { $0 != "library-owner" }
        try writer.read {
            _ = try SyncDatabase.checkEnrollment(
                $0, role: "client", deviceID: deviceID, binding: binding,
                hasUnboundBlobs: hasUnboundBlobs)
        }
        guard blobs.binding == binding else { throw SyncBindingError.mismatch }
        self.binding = binding
        self.writer = writer
        writerIdentity = writer.writeWithoutTransaction { ObjectIdentifier($0) }
        self.blobs = blobs
        self.project = project
        self.deviceID = try SyncDatabase.prepare(
            writer, role: "client", deviceID: deviceID, binding: binding,
            hasUnboundBlobs: hasUnboundBlobs, prepareProjection: prepareProjection)!
        try write(pruneHistory)
    }

    func read<T>(_ body: (Database) throws -> T) throws -> T {
        try writer.read { db in
            try SyncDatabase.checkBinding(db, binding)
            return try body(db)
        }
    }

    func write<T>(_ body: (Database) throws -> T) throws -> T {
        try writer.write { db in
            try SyncDatabase.checkBinding(db, binding)
            return try body(db)
        }
    }

    @discardableResult
    public func enqueue(captureID: UUID, mutation: CaptureMutation, baseRevision: Int64? = nil)
        throws -> SyncOperation
    {
        try projectionGate.check()
        return try write { db in
            try enqueue(
                in: db, captureID: captureID, mutation: mutation, baseRevision: baseRevision)
        }
    }

    /// Enlists in this client's writer transaction. Propagate errors so the caller rolls back all work.
    @discardableResult
    public func enqueue(
        in db: Database, captureID: UUID, mutation: CaptureMutation, baseRevision: Int64? = nil
    ) throws -> SyncOperation {
        guard ObjectIdentifier(db) == writerIdentity else { throw SyncTransactionError.wrongWriter }
        guard db.isInsideTransaction else { throw SyncTransactionError.requiresTransaction }
        try projectionGate.check()
        try SyncDatabase.checkBinding(db, binding)
        if case .create(let record) = mutation, let blob = record.source.blob {
            _ = try blobs.read(blob)
        }
        let id = try SyncDatabase.canonical(db, captureID)
        if case .create = mutation,
            try SyncDatabase.record(db, id: id, table: "sync_visible") != nil
        {
            throw SyncError.invalidOperation
        }
        let acceptedRevision = try SyncDatabase.record(db, id: id)?.revision ?? 0
        let base = baseRevision ?? acceptedRevision
        guard base >= 0, base <= acceptedRevision else { throw SyncError.invalidOperation }
        if case .restore = mutation,
            let record = try SyncDatabase.record(db, id: id, table: "sync_visible"),
            record.deleted, record.revision == base, let blob = record.source.blob
        {
            _ = try blobs.read(blob)
        }
        let pending = try operations(db)
        let predecessor = try pending.last {
            try SyncDatabase.canonical(db, $0.captureID) == id
        }
        let previousSequence = try Int64.fetchOne(db, sql: "SELECT sequence FROM sync_meta")!
        guard previousSequence < Int64.max else { throw SyncError.invalidOperation }
        let sequence = previousSequence + 1
        let operation = SyncOperation(
            deviceID: deviceID, sequence: sequence,
            captureID: captureID, baseRevision: base, predecessorID: predecessor?.id,
            mutation: mutation)
        try SyncDatabase.validate(operation)
        try validateRequest(operation)
        try db.execute(
            sql: "INSERT INTO sync_outbox (sequence, id, payload) VALUES (?, ?, ?)",
            arguments: [sequence, operation.id.uuidString, try SyncDatabase.encode(operation)])
        try db.execute(sql: "UPDATE sync_meta SET sequence = ?", arguments: [sequence])
        let validating: [UUID] = if case .delete = mutation { [] } else { [captureID] }
        try rebuild(db, validating: validating)
        return operation
    }

    /// Validates pending and projected replies inside this client's writer transaction.
    /// Propagate errors so the caller rolls back pending work.
    public func validateResponseBudget(in db: Database, captureID: UUID) throws {
        guard ObjectIdentifier(db) == writerIdentity else { throw SyncTransactionError.wrongWriter }
        guard db.isInsideTransaction else { throw SyncTransactionError.requiresTransaction }
        try projectionGate.check()
        try SyncDatabase.checkBinding(db, binding)
        let id = try SyncDatabase.canonical(db, captureID)
        let deviceCount =
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM sync_devices WHERE id != ? COLLATE NOCASE",
                arguments: [deviceID.uuidString])! + 1
        let budget = try SyncHTTPResponseBudget(
            principal: SyncPrincipal(
                serviceID: binding?.serviceID ?? deviceID,
                libraryID: binding?.libraryID ?? deviceID, deviceID: deviceID),
            deviceCount: deviceCount)
        try validatePendingReplies(
            db, captureIDs: [id], budget: budget,
            observed: try String.fetchSet(db, sql: "SELECT id FROM sync_observed"),
            observedSequence: try Int64.fetchOne(
                db, sql: "SELECT observed_sequence FROM sync_meta")!)
        if let record = try SyncDatabase.record(db, id: id, table: "sync_visible"), !record.deleted
        {
            try budget.validateMutationCapture(record)
        }
    }

    /// Enqueues an ordered batch of edits and rebuilds its projection once in the caller's transaction.
    @discardableResult
    public func enqueue(in db: Database, edits: [(captureID: UUID, edit: CaptureEdit)]) throws
        -> [SyncOperation]
    {
        try enqueue(in: db, mutations: edits.map { ($0.captureID, .edit($0.edit)) })
    }

    /// Enqueues ordered tombstones and rebuilds their projection once in the caller's transaction.
    @discardableResult
    public func enqueue(in db: Database, deletions: [UUID]) throws -> [SyncOperation] {
        try enqueue(in: db, mutations: deletions.map { ($0, .delete) })
    }

    /// Enqueues at most 100 creates, recaptures, or edits and rebuilds once in the caller's transaction.
    /// Propagate errors so the caller rolls back all staged source rows and operations.
    @discardableResult
    public func enqueueCaptures(
        in db: Database, mutations: [(captureID: UUID, mutation: CaptureMutation)]
    ) throws -> [SyncOperation] {
        guard mutations.count <= 100,
            mutations.allSatisfy({
                switch $0.mutation {
                case .create, .recapture, .edit: true
                case .delete, .restore: false
                }
            })
        else { throw SyncError.invalidOperation }
        return try enqueue(in: db, mutations: mutations)
    }

    private func enqueue(
        in db: Database, mutations: [(captureID: UUID, mutation: CaptureMutation)]
    ) throws -> [SyncOperation] {
        guard ObjectIdentifier(db) == writerIdentity else { throw SyncTransactionError.wrongWriter }
        guard db.isInsideTransaction else { throw SyncTransactionError.requiresTransaction }
        try projectionGate.check()
        try SyncDatabase.checkBinding(db, binding)
        guard !mutations.isEmpty else { return [] }
        var predecessors: [UUID: UUID] = [:]
        for pending in try operations(db) {
            predecessors[try SyncDatabase.canonical(db, pending.captureID)] = pending.id
        }
        var sequence = try Int64.fetchOne(db, sql: "SELECT sequence FROM sync_meta")!
        var appended: [SyncOperation] = []
        var created: Set<UUID> = []
        var sources: [UUID: CaptureSource] = [:]
        if mutations.contains(where: { if case .create = $0.mutation { true } else { false } }) {
            sources = Dictionary(
                uniqueKeysWithValues: try SyncDatabase.records(db, table: "sync_visible")
                    .map { ($0.id, $0.source) })
        }
        for (captureID, mutation) in mutations {
            let id = try SyncDatabase.canonical(db, captureID)
            if case .create(let record) = mutation {
                if let blob = record.source.blob { _ = try blobs.read(blob) }
                guard !created.contains(id),
                    try SyncDatabase.record(db, id: id, table: "sync_visible") == nil
                else { throw SyncError.invalidOperation }
                created.insert(id)
            }
            let base = try SyncDatabase.record(db, id: id)?.revision ?? 0
            guard sequence < Int64.max else { throw SyncError.invalidOperation }
            sequence += 1
            let operation = SyncOperation(
                deviceID: deviceID, sequence: sequence,
                captureID: captureID,
                baseRevision: base,
                predecessorID: predecessors[id], mutation: mutation)
            try SyncDatabase.validate(operation)
            try validateRequest(operation)
            try db.execute(
                sql: "INSERT INTO sync_outbox (sequence, id, payload) VALUES (?, ?, ?)",
                arguments: [sequence, operation.id.uuidString, try SyncDatabase.encode(operation)])
            predecessors[id] = operation.id
            if case .create(let incoming) = mutation {
                if sources[id] == nil,
                    let duplicate = sources.filter({
                        CaptureFingerprint.matches($0.value, incoming.source)
                    }).keys.min(by: { $0.uuidString < $1.uuidString })
                {
                    try SyncDatabase.alias(db, incoming.id, to: duplicate)
                    predecessors[duplicate] = operation.id
                } else {
                    sources[id] = incoming.source
                }
            }
            appended.append(operation)
        }
        try db.execute(sql: "UPDATE sync_meta SET sequence = ?", arguments: [sequence])
        try rebuild(
            db,
            validating: mutations.compactMap {
                if case .delete = $0.1 { return nil }
                return $0.0
            })
        return appended
    }

    /// Export visible content without changing the original device history or pending BLOBs.
    public func contentSnapshotImport(snapshotID: UUID, targetBinding: SyncLibraryBinding) throws
        -> ContentSnapshotImport
    {
        try read { db in
            ContentSnapshotImport(
                snapshotID: snapshotID, targetBinding: targetBinding, sourceDeviceID: deviceID,
                captures: try SyncDatabase.records(db, table: "sync_visible"),
                websiteIcons: try WebsiteIconDatabase.exists(db)
                    ? Self.exportWebsiteIcons(in: db, includeDeleted: true) : nil)
        }
    }

    public func pendingOperations() throws -> [SyncOperation] { try read(operations) }

    private func operations(_ db: Database) throws -> [SyncOperation] {
        try Data.fetchAll(db, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
            .map { try SyncDatabase.decode(SyncOperation.self, $0) }
    }

    public func rejectedWork() throws -> [RejectedWork] {
        try read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM sync_rejections ORDER BY id")
                .map { try SyncDatabase.decode(RejectedWork.self, $0) }
        }
    }

    public func captures(includeDeleted: Bool = false) throws -> [SharedCapture] {
        try read { db in
            try SyncDatabase.records(db, table: "sync_visible").filter {
                includeDeleted || !$0.deleted
            }
        }
    }

    public func cursor() throws -> Int64 {
        try read { db in try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta")! }
    }

    /// Uploads in device order; a lost acknowledgement leaves the exact operation ready to retry.
    @discardableResult
    public func push(to transport: any SyncTransport) throws -> [SyncReceipt] {
        try checkBinding(transport)
        try Task.checkCancellation()
        var receipts: [SyncReceipt] = []
        for operation in try pendingOperations() {
            try Task.checkCancellation()
            if case .create(let record) = operation.mutation, let blob = record.source.blob {
                let data = try blobs.read(blob)
                if data.isEmpty {
                    try transport.upload(blob, offset: 0, chunk: Data(), final: true)
                } else {
                    for offset in stride(from: 0, to: data.count, by: 65_536) {
                        try Task.checkCancellation()
                        let end = min(offset + 65_536, data.count)
                        try transport.upload(
                            blob, offset: offset,
                            chunk: data.subdata(in: offset..<end), final: end == data.count)
                    }
                }
            }
            let receipt = try transport.apply(operation)
            try read { try validate(receipt, for: operation, in: $0) }
            try cacheBlob(receipt.capture, from: transport)
            try acknowledge(operation, receipt: receipt)
            receipts.append(receipt)
        }
        return receipts
    }

    private func acknowledge(_ operation: SyncOperation, receipt: SyncReceipt) throws {
        try write { db in
            guard let pending = try operations(db).first, pending == operation else {
                throw SyncError.invalidOperation
            }
            try validate(receipt, for: operation, in: db)
            try observeDevice(operation.deviceID, sequence: operation.sequence, in: db)
            try retainReceipt(receipt, for: operation, in: db)
            if let record = receipt.capture {
                try SyncDatabase.alias(db, operation.captureID, to: record.id)
                try accept(db, record)
            }
            if receipt.outcome != .accepted && receipt.outcome != .noteConflict {
                try db.execute(
                    sql: "INSERT INTO sync_rejections (id, payload) VALUES (?, ?)",
                    arguments: [
                        operation.id.uuidString,
                        try SyncDatabase.encode(
                            RejectedWork(operation: operation, receipt: receipt)),
                    ])
            }
            try db.execute(
                sql: "DELETE FROM sync_outbox WHERE id = ?", arguments: [operation.id.uuidString])
            try db.execute(
                sql: "DELETE FROM sync_observed WHERE id = ?", arguments: [operation.id.uuidString])
            try rebuild(db)
        }
    }

    private func validate(_ receipt: SyncReceipt, for operation: SyncOperation, in db: Database)
        throws
    {
        guard receipt.operationID == operation.id else { throw SyncError.invalidOperation }
        if receipt.outcome == .missing {
            guard receipt.capture == nil else { throw SyncError.invalidOperation }
            if case .create = operation.mutation { throw SyncError.invalidOperation }
            return
        }
        guard let record = receipt.capture else { throw SyncError.invalidOperation }
        try SyncDatabase.validateHistorical(record)
        let current = try SyncDatabase.record(db, id: record.id)
        try validateIdentity(record, replacing: current)
        let observed =
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM sync_observed WHERE id = ?)",
                arguments: [operation.id.uuidString])!
            || operation.sequence <= Int64.fetchOne(
                db, sql: "SELECT observed_sequence FROM sync_meta")!
        if let current, !observed, record.revision > 0,
            record.revision - 1 == current.revision,
            receipt.outcome == .accepted || receipt.outcome == .noteConflict
        {
            try validateTransition(receipt, for: operation, from: current, in: db)
        }
        let id = try SyncDatabase.canonical(db, operation.captureID)
        if record.id != id {
            guard case .create(let incoming) = operation.mutation,
                CaptureFingerprint.matches(record.source, incoming.source)
            else { throw SyncError.invalidOperation }
        }
        switch receipt.outcome {
        case .accepted:
            let deleted: Bool
            if case .delete = operation.mutation { deleted = true } else { deleted = false }
            guard record.deleted == deleted, record.revision > operation.baseRevision else {
                throw SyncError.invalidOperation
            }
            if let current, !observed {
                guard record.revision > current.revision else { throw SyncError.invalidOperation }
                switch operation.mutation {
                case .recapture, .create:
                    guard record.seenCount == Int.max || record.seenCount > current.seenCount else {
                        throw SyncError.invalidOperation
                    }
                default: break
                }
            }
            switch operation.mutation {
            case .create(var incoming):
                if record.id == incoming.id {
                    incoming.revision = record.revision
                    incoming.noteRevision = incoming.note == nil ? 0 : record.revision
                    incoming.noteOperationID = operation.id
                    incoming.manualTags = Array(Set(incoming.manualTags)).sorted()
                    guard record == incoming else { throw SyncError.invalidOperation }
                } else {
                    guard CaptureFingerprint.matches(record.source, incoming.source),
                        record.seenCount >= 2,
                        Set(record.manualTags).isSuperset(of: incoming.manualTags),
                        incoming.note == nil || containsNote(record, incoming.note)
                    else { throw SyncError.invalidOperation }
                }
            case .edit(let edit):
                var expected = record
                _ = try SyncDatabase.edit(
                    &expected, edit, operation: operation, base: record.revision, server: false)
                guard expected.source == record.source,
                    edit.note == nil || containsNote(record, expected.note),
                    expected.rating == record.rating, expected.manualTags == record.manualTags,
                    expected.generated == record.generated, expected.metadata == record.metadata
                else { throw SyncError.invalidOperation }
            default: break
            }
        case .noteConflict:
            let hasNote: Bool
            switch operation.mutation {
            case .create(let incoming): hasNote = incoming.note != nil
            case .edit(let edit): hasNote = edit.note != nil
            default: hasNote = false
            }
            guard hasNote, !record.deleted,
                record.noteConflicts.contains(where: { $0.operationID == operation.id }),
                record.revision > operation.baseRevision
            else { throw SyncError.invalidOperation }
            if let current, !observed {
                guard record.revision > current.revision else { throw SyncError.invalidOperation }
            }
        case .deleted:
            guard record.deleted else { throw SyncError.invalidOperation }
            if case .restore = operation.mutation { throw SyncError.invalidOperation }
        case .staleRestore:
            guard case .restore = operation.mutation else { throw SyncError.invalidOperation }
        case .alreadyExists:
            guard case .create = operation.mutation, !record.deleted else {
                throw SyncError.invalidOperation
            }
        case .missing: break
        }
    }

    public func pull(from transport: any SyncTransport, limit: Int = 100) throws {
        try checkBinding(transport)
        try Task.checkCancellation()
        let oldCursor = try cursor()
        do {
            let page = try transport.changes(after: oldCursor, limit: limit)
            try validate(page, after: oldCursor)
            for change in page.changes { try cacheBlob(change.capture, from: transport) }
            try Task.checkCancellation()
            try commit(page, after: oldCursor)
        } catch SyncError.cursorExpired {
            let baseline = try transport.baseline()
            try validate(baseline, after: oldCursor)
            for record in baseline.captures { try cacheBlob(record, from: transport) }
            try Task.checkCancellation()
            try commit(baseline, after: oldCursor)
        }
    }

    /// Uses durable outbox retries. The wire executor never retries a POST on its own.
    @discardableResult
    public func syncOnce(
        using transport: any AsyncSyncTransport,
        credential: @escaping @Sendable () throws -> String
    ) async throws -> [SyncReceipt] {
        do {
            try await pull(from: transport, credential: credential)
        } catch SyncError.recoverySequenceCollision {}
        let receipts = try await push(to: transport, credential: credential)
        try await pull(from: transport, credential: credential)
        return receipts
    }

    @discardableResult
    public func push(
        to transport: any AsyncSyncTransport,
        credential: @escaping @Sendable () throws -> String
    ) async throws -> [SyncReceipt] {
        try checkBinding(transport)
        try Task.checkCancellation()
        let actions = AsyncHTTPActions(transport: transport, credential: credential)
        var receipts: [SyncReceipt] = []
        for operation in try pendingOperations() {
            try Task.checkCancellation()
            if case .create(let record) = operation.mutation, let blob = record.source.blob {
                let data = try blobs.read(blob)
                if data.isEmpty {
                    try await actions.upload(blob, offset: 0, chunk: Data(), final: true)
                } else {
                    for offset in stride(from: 0, to: data.count, by: 65_536) {
                        try Task.checkCancellation()
                        let end = min(offset + 65_536, data.count)
                        try await actions.upload(
                            blob, offset: offset, chunk: data.subdata(in: offset..<end),
                            final: end == data.count)
                    }
                }
            }
            let receipt = try await actions.apply(operation)
            try read { try validate(receipt, for: operation, in: $0) }
            try await cacheBlob(receipt.capture, from: actions)
            try Task.checkCancellation()
            try acknowledge(operation, receipt: receipt)
            receipts.append(receipt)
        }
        return receipts
    }

    public func pull(
        from transport: any AsyncSyncTransport, limit: Int = 100,
        credential: @escaping @Sendable () throws -> String
    ) async throws {
        try checkBinding(transport)
        try Task.checkCancellation()
        let actions = AsyncHTTPActions(transport: transport, credential: credential)
        let oldCursor = try cursor()
        do {
            let page = try await actions.changes(after: oldCursor, limit: limit)
            try validate(page, after: oldCursor)
            for change in page.changes { try await cacheBlob(change.capture, from: actions) }
            try Task.checkCancellation()
            try commit(page, after: oldCursor)
        } catch SyncError.cursorExpired {
            let baseline = try await actions.baseline()
            try validate(baseline, after: oldCursor)
            for record in baseline.captures { try await cacheBlob(record, from: actions) }
            try Task.checkCancellation()
            try commit(baseline, after: oldCursor)
        }
    }

    private func checkBinding(_ transport: any AsyncSyncTransport) throws {
        try read { _ in }
        guard let binding else { throw SyncBindingError.bindingRequired }
        guard binding == transport.binding else { throw SyncBindingError.mismatch }
        guard deviceID == transport.deviceID else { throw SyncError.wrongDevice }
    }

    private func cacheBlob(_ record: SharedCapture?, from actions: AsyncHTTPActions) async throws {
        guard let record, let blob = record.source.blob else { return }
        do { _ = try blobs.read(blob) } catch SyncError.blobMissing, SyncError.invalidBlob {
            let data = try await actions.download(blob)
            try Task.checkCancellation()
            try blobs.receive(blob, offset: 0, chunk: data, final: true)
        }
    }

    private func validate(_ page: FeedPage, after oldCursor: Int64) throws {
        try write { db in
            try db.inSavepoint {
                var cursor = oldCursor
                for change in page.changes {
                    guard cursor < Int64.max, change.cursor == cursor + 1,
                        change.capture.revision == change.cursor
                    else { throw SyncError.invalidCursor }
                    try accept(change, in: db)
                    cursor = change.cursor
                }
                guard page.cursor == cursor else { throw SyncError.invalidCursor }
                return .rollback
            }
        }
    }

    private func accept(_ change: FeedChange, in db: Database) throws {
        try SyncDatabase.validateHistorical(change.capture)
        try validateIdentity(
            change.capture, replacing: SyncDatabase.record(db, id: change.capture.id))
        if change.deviceID == deviceID {
            try validateLocalChange(change, in: db)
            try SyncDatabase.alias(db, change.requestedCaptureID, to: change.capture.id)
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO sync_observed (id)
                    SELECT id FROM sync_outbox WHERE id = ?
                    """,
                arguments: [change.operationID.uuidString])
        }
        try accept(db, change.capture)
        try observeDevice(change.deviceID, sequence: change.sequence, in: db)
    }

    private func commit(_ page: FeedPage, after oldCursor: Int64) throws {
        try validate(page, after: oldCursor)
        try write { db in
            guard try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta") == oldCursor
            else {
                throw SyncError.invalidCursor
            }
            for change in page.changes { try accept(change, in: db) }
            try rebuild(db)
            try db.execute(sql: "UPDATE sync_meta SET cursor = ?", arguments: [page.cursor])
        }
    }

    private func commit(_ baseline: Baseline, after oldCursor: Int64) throws {
        try validate(baseline, after: oldCursor)
        try write { db in
            guard try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta") == oldCursor
            else { throw SyncError.invalidCursor }
            try validateBaselineRecords(baseline, in: db)
            for (device, sequence) in baseline.deviceSequences {
                try observeDevice(device, sequence: sequence, in: db)
            }
            let acceptedSequence = baseline.deviceSequences[deviceID] ?? 0
            try pruneHistory(db)
            let observed = try String.fetchSet(db, sql: "SELECT id FROM sync_observed")
            guard
                try !operations(db).contains(where: {
                    $0.sequence <= acceptedSequence && !observed.contains($0.id.uuidString)
                })
            else { throw SyncError.recoverySequenceCollision }
            // A push acknowledgement can already be ahead of this baseline snapshot.
            let ahead = try SyncDatabase.records(db).filter { $0.revision > baseline.cursor }
            try db.execute(sql: "DELETE FROM sync_records")
            for record in baseline.captures + ahead { try accept(db, record) }
            try db.execute(
                sql: """
                    UPDATE sync_meta SET observed_sequence = MAX(observed_sequence, ?),
                        sequence = MAX(sequence, ?)
                    """,
                arguments: [acceptedSequence, acceptedSequence])
            try rebuild(db)
            try db.execute(sql: "UPDATE sync_meta SET cursor = ?", arguments: [baseline.cursor])
        }
    }

    private func validate(_ baseline: Baseline, after oldCursor: Int64) throws {
        guard baseline.cursor >= oldCursor, baseline.totalCaptureCount == baseline.captures.count,
            Set(baseline.captures.map(\.id)).count == baseline.captures.count,
            baseline.captures.allSatisfy({ $0.revision >= 0 && $0.revision <= baseline.cursor })
        else { throw SyncError.invalidCursor }
        try read { try validateBaselineRecords(baseline, in: $0) }
    }

    private func validateBaselineRecords(_ baseline: Baseline, in db: Database) throws {
        for record in baseline.captures {
            try SyncDatabase.validateHistorical(record)
            try validateIdentity(record, replacing: SyncDatabase.record(db, id: record.id))
        }
        let revisions = Dictionary(
            uniqueKeysWithValues: baseline.captures.map { ($0.id.uuidString, $0.revision) })
        let rows = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, json_extract(CAST(payload AS TEXT), '$.revision') AS revision
                FROM sync_records WHERE revision <= ?
                """, arguments: [baseline.cursor])
        while let row = try rows.next() {
            let id: String = row["id"]
            let revision: Int64 = row["revision"]
            guard let incoming = revisions[id], incoming >= revision else {
                throw SyncError.invalidCursor
            }
        }
    }

    private func validateTransition(
        _ receipt: SyncReceipt, for operation: SyncOperation, from current: SharedCapture,
        in db: Database
    ) throws {
        guard let received = receipt.capture else { throw SyncError.invalidOperation }
        if try preview(
            operation, from: current, revision: received.revision,
            base: operation.baseRevision) == receipt
        {
            return
        }
        if try preview(
            operation, from: current, revision: received.revision,
            base: causalBase(for: operation, in: db)) == receipt
        {
            return
        }
        throw SyncError.invalidOperation
    }

    private func preview(
        _ operation: SyncOperation, from current: SharedCapture?, revision: Int64, base: Int64
    ) throws -> SyncReceipt? {
        guard let current else {
            guard case .create(var incoming) = operation.mutation else { return nil }
            incoming.revision = revision
            incoming.noteRevision = incoming.note == nil ? 0 : revision
            incoming.noteOperationID = operation.id
            incoming.manualTags = Array(Set(incoming.manualTags)).sorted()
            return SyncReceipt(operationID: operation.id, outcome: .accepted, capture: incoming)
        }
        var record = current
        record.revision = revision
        var conflict = false
        switch operation.mutation {
        case .create(let incoming):
            guard incoming.id != current.id, !current.deleted,
                CaptureFingerprint.matches(incoming.source, current.source)
            else { return nil }
            SyncDatabase.fillSourceContent(
                &record.source,
                from: SourceContentPatch(
                    title: incoming.source.title, selection: incoming.source.selection))
            if record.seenCount < Int.max { record.seenCount += 1 }
            record.manualTags = Array(Set(record.manualTags).union(incoming.manualTags))
                .sorted()
            if incoming.note != nil {
                conflict = try SyncDatabase.edit(
                    &record, CaptureEdit(note: NoteEdit(incoming.note)),
                    operation: operation, base: 0, server: true)
            }
        case .edit(let edit):
            guard !current.deleted else { return nil }
            conflict = try SyncDatabase.edit(
                &record, edit, operation: operation, base: base, server: true)
        case .recapture:
            guard !current.deleted else { return nil }
            if record.seenCount < Int.max { record.seenCount += 1 }
        case .delete:
            guard !current.deleted else { return nil }
            record.deleted = true
        case .restore:
            guard current.deleted, operation.baseRevision == current.revision else {
                return nil
            }
            record.deleted = false
        }
        return SyncReceipt(
            operationID: operation.id, outcome: conflict ? .noteConflict : .accepted,
            capture: record)
    }

    private func causalBase(
        for operation: SyncOperation, in db: Database,
        pending: [UUID: SyncOperation] = [:], simulated: [UUID: SyncReceipt] = [:]
    ) throws -> Int64 {
        let id = try SyncDatabase.canonical(db, operation.captureID)
        var predecessorID = operation.predecessorID
        var precedingSequence = operation.sequence
        while let priorID = predecessorID {
            let predecessor: SyncOperation
            let receipt: SyncReceipt
            if let operation = pending[priorID], let preview = simulated[priorID] {
                predecessor = operation
                receipt = preview
            } else if let row = try Row.fetchOne(
                db, sql: "SELECT operation, receipt FROM sync_receipts WHERE id = ?",
                arguments: [priorID.uuidString])
            {
                predecessor = try SyncDatabase.decode(SyncOperation.self, row["operation"])
                receipt = try SyncDatabase.decode(SyncReceipt.self, row["receipt"])
            } else {
                break
            }
            guard predecessor.deviceID == operation.deviceID,
                predecessor.sequence < precedingSequence,
                try SyncDatabase.canonical(db, predecessor.captureID) == id
            else { throw SyncError.invalidOperation }
            if let capture = receipt.capture, capture.noteOperationID == predecessor.id {
                return max(operation.baseRevision, capture.noteRevision)
            }
            precedingSequence = predecessor.sequence
            predecessorID = predecessor.predecessorID
        }
        return operation.baseRevision
    }

    private func retainReceipt(
        _ receipt: SyncReceipt, for operation: SyncOperation, in db: Database
    ) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO sync_receipts (id, operation, receipt) VALUES (?, ?, ?)",
            arguments: [
                operation.id.uuidString, try SyncDatabase.encode(operation),
                try SyncDatabase.encode(receipt),
            ])
    }

    private func validateIdentity(_ record: SharedCapture, replacing current: SharedCapture?) throws
    {
        guard let current else { return }
        guard sameIdentity(record, current) else { throw SyncError.invalidOperation }
        if record.revision == current.revision {
            guard record == current else { throw SyncError.invalidOperation }
        } else if record.revision > current.revision {
            guard
                current.source.title?.isEmpty ?? true
                    || record.source.title == current.source.title,
                current.source.selection?.isEmpty ?? true
                    || record.source.selection == current.source.selection
            else { throw SyncError.invalidOperation }
        }
    }

    private func validateLocalChange(_ change: FeedChange, in db: Database) throws {
        if let pending = try operations(db).first(where: { $0.id == change.operationID }) {
            guard pending.captureID == change.requestedCaptureID,
                pending.sequence == change.sequence
            else { throw SyncError.invalidOperation }
            let outcome: SyncReceipt.Outcome =
                change.capture.noteConflicts.contains(where: { $0.operationID == pending.id })
                ? .noteConflict : .accepted
            let receipt = SyncReceipt(
                operationID: pending.id, outcome: outcome, capture: change.capture)
            try validate(receipt, for: pending, in: db)
            try retainReceipt(receipt, for: pending, in: db)
            if change.requestedCaptureID == change.capture.id { return }
            if case .create(let incoming) = pending.mutation,
                CaptureFingerprint.matches(incoming.source, change.capture.source)
            {
                return
            }
        }
        guard change.requestedCaptureID != change.capture.id else { return }
        guard try SyncDatabase.canonical(db, change.requestedCaptureID) == change.capture.id,
            let current = try SyncDatabase.record(db, id: change.capture.id),
            sameIdentity(current, change.capture)
        else { throw SyncError.invalidOperation }
    }

    private func sameIdentity(_ lhs: SharedCapture, _ rhs: SharedCapture) -> Bool {
        lhs.createdAt == rhs.createdAt && lhs.source.kind == rhs.source.kind
            && lhs.source.contentHash == rhs.source.contentHash && lhs.source.url == rhs.source.url
            && lhs.source.host == rhs.source.host && lhs.source.blob == rhs.source.blob
            && (lhs.source.selection?.isEmpty ?? true || rhs.source.selection?.isEmpty ?? true
                || lhs.source.selection == rhs.source.selection)
            && (lhs.source.title?.isEmpty ?? true || rhs.source.title?.isEmpty ?? true
                || lhs.source.title == rhs.source.title)
    }

    private func containsNote(_ record: SharedCapture, _ value: String?) -> Bool {
        record.note == value || record.noteConflicts.contains(where: { $0.value == value })
    }

    private func checkBinding(_ transport: any SyncTransport) throws {
        try read { _ in }
        let bound = transport as? any BoundSyncTransport
        guard binding == bound?.binding else { throw SyncBindingError.mismatch }
        if binding != nil {
            guard let bound else { throw SyncBindingError.bindingRequired }
            guard bound.deviceID == deviceID else { throw SyncError.wrongDevice }
        }
    }

    private func cacheBlob(_ record: SharedCapture?, from transport: any SyncTransport) throws {
        guard let record, let blob = record.source.blob else { return }
        do { _ = try blobs.read(blob) } catch SyncError.blobMissing, SyncError.invalidBlob {
            let data = try transport.download(blob)
            try blobs.receive(blob, offset: 0, chunk: data, final: true)
        }
    }

    private func accept(_ db: Database, _ record: SharedCapture) throws {
        if let current = try SyncDatabase.record(db, id: record.id),
            current.revision > record.revision
        {
            return
        }
        try SyncDatabase.save(db, record)
    }

    private func validateRequest(_ operation: SyncOperation) throws {
        guard let binding else { return }
        let action = SyncHTTPAction.apply(operation)
        let envelope = SyncHTTPEnvelope(
            version: action.requiredEnvelopeVersion, expectedServiceID: binding.serviceID,
            expectedLibraryID: binding.libraryID, expectedDeviceID: deviceID, action: action)
        guard try SyncDatabase.encode(envelope).count <= SyncHTTPHandler.maximumBodyBytes else {
            throw SyncHTTPError.requestTooLarge
        }
    }

    private func observeDevice(_ device: UUID, sequence: Int64, in db: Database) throws {
        guard sequence >= 0 else { throw SyncError.invalidOperation }
        try db.execute(
            sql: """
                INSERT INTO sync_devices (id, sequence) VALUES (?, ?)
                ON CONFLICT(id) DO UPDATE SET sequence=MAX(sequence, excluded.sequence)
                """, arguments: [device.uuidString, sequence])
    }

    private func validatePendingReplies(
        _ db: Database, captureIDs: Set<UUID>, budget: SyncHTTPResponseBudget,
        observed: Set<String>, observedSequence: Int64
    ) throws {
        var records: [UUID: SharedCapture] = [:]
        for id in captureIDs { records[id] = try SyncDatabase.record(db, id: id) }
        let pending = try operations(db)
        let indexed = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        var receipts: [UUID: SyncReceipt] = [:]
        let cursor = try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta")!
        for operation in pending {
            let id = try SyncDatabase.canonical(db, operation.captureID)
            guard captureIDs.contains(id), !observed.contains(operation.id.uuidString),
                operation.sequence > observedSequence
            else { continue }
            let base = try causalBase(
                for: operation, in: db, pending: indexed, simulated: receipts)
            let priorRevision = max(cursor, records[id]?.revision ?? 0)
            let revision = priorRevision == Int64.max ? Int64.max : priorRevision + 1
            guard
                let receipt = try preview(
                    operation, from: records[id], revision: revision,
                    base: base), let capture = receipt.capture
            else { continue }
            records[id] = capture
            receipts[operation.id] = receipt
            if !capture.deleted { try budget.validateMutationCapture(capture) }
        }
    }

    private func rebuild(_ db: Database, validating captureIDs: [UUID] = []) throws {
        let before = try SyncDatabase.records(db, table: "sync_visible")
        try pruneHistory(db)
        let observed = try String.fetchSet(db, sql: "SELECT id FROM sync_observed")
        let observedSequence = try Int64.fetchOne(
            db, sql: "SELECT observed_sequence FROM sync_meta")!
        var records = Dictionary(
            uniqueKeysWithValues: try SyncDatabase.records(db).map { ($0.id, $0) })
        for operation in try operations(db) {
            var id = try SyncDatabase.canonical(db, operation.captureID)
            if case .create(let incoming) = operation.mutation {
                if records[id] == nil,
                    let duplicate = records.values.lazy.filter({
                        CaptureFingerprint.matches($0.source, incoming.source)
                    }).min(by: { $0.id.uuidString < $1.id.uuidString })
                {
                    id = duplicate.id
                    try SyncDatabase.alias(db, incoming.id, to: id)
                }
                if observed.contains(operation.id.uuidString)
                    || operation.sequence <= observedSequence
                {
                    continue
                }
                if var existing = records[id] {
                    if !existing.deleted {
                        SyncDatabase.fillSourceContent(
                            &existing.source,
                            from: SourceContentPatch(
                                title: incoming.source.title, selection: incoming.source.selection))
                        if existing.seenCount < Int.max { existing.seenCount += 1 }
                        if incoming.note != nil { existing.note = incoming.note }
                        existing.manualTags = Array(
                            Set(existing.manualTags).union(incoming.manualTags)
                        ).sorted()
                    }
                    records[id] = existing
                } else {
                    records[id] = incoming
                }
                continue
            }
            if observed.contains(operation.id.uuidString) || operation.sequence <= observedSequence
            {
                continue
            }
            guard var record = records[id] else { continue }
            switch operation.mutation {
            case .edit(let edit):
                if !record.deleted {
                    _ = try SyncDatabase.edit(
                        &record, edit, operation: operation,
                        base: record.revision, server: false)
                }
            case .recapture:
                if !record.deleted, record.seenCount < Int.max { record.seenCount += 1 }
            case .delete: record.deleted = true
            case .restore:
                // Restoration is optimistic only at the tombstone revision the user saw.
                if record.deleted && record.revision == operation.baseRevision {
                    record.deleted = false
                }
            case .create: break
            }
            records[id] = record
        }
        if let binding, !captureIDs.isEmpty {
            let deviceCount =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM sync_devices WHERE id != ? COLLATE NOCASE",
                    arguments: [deviceID.uuidString])! + 1
            let budget = try SyncHTTPResponseBudget(
                principal: SyncPrincipal(
                    serviceID: binding.serviceID, libraryID: binding.libraryID, deviceID: deviceID),
                deviceCount: deviceCount)
            let ids = Set(try captureIDs.map { try SyncDatabase.canonical(db, $0) })
            try validatePendingReplies(
                db, captureIDs: ids, budget: budget,
                observed: observed, observedSequence: observedSequence)
            for id in ids {
                if let record = records[id], !record.deleted {
                    try budget.validateMutationCapture(record)
                }
            }
        }
        for old in before where records[old.id] == nil {
            var removed = old
            removed.deleted = true
            try projectionGate.project { try project(db, removed) }
            try db.execute(
                sql: "DELETE FROM sync_visible WHERE id = ?", arguments: [old.id.uuidString])
        }
        for record in records.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try SyncDatabase.save(db, record, table: "sync_visible")
            try projectionGate.project { try project(db, record) }
        }
    }

    private func pruneHistory(_ db: Database) throws {
        try db.execute(
            sql: "DELETE FROM sync_observed WHERE id NOT IN (SELECT id FROM sync_outbox)")
        let pending = try operations(db)
        let retained = try Data.fetchAll(db, sql: "SELECT operation FROM sync_receipts")
            .map { try SyncDatabase.decode(SyncOperation.self, $0) }
        let history = Dictionary(
            (retained + pending).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var needed = Set<UUID>()
        for operation in pending {
            var id: UUID? = operation.id
            while let current = id, needed.insert(current).inserted {
                id = history[current]?.predecessorID
            }
        }
        for operation in retained where !needed.contains(operation.id) {
            try db.execute(
                sql: "DELETE FROM sync_receipts WHERE id = ?", arguments: [operation.id.uuidString])
        }
    }
}

public enum SyncTransactionError: Error, Equatable, Sendable {
    case wrongWriter, requiresTransaction, projectionFeedback
}

final class ProjectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeThread: ObjectIdentifier?

    func check() throws {
        if lock.withLock({ activeThread == ObjectIdentifier(Thread.current) }) {
            throw SyncTransactionError.projectionFeedback
        }
    }

    func project(_ body: () throws -> Void) throws {
        lock.withLock { activeThread = ObjectIdentifier(Thread.current) }
        defer { lock.withLock { activeThread = nil } }
        try body()
    }
}
