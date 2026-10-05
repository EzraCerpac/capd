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
    private let writer: any DatabaseWriter
    private let writerIdentity: ObjectIdentifier
    private let projectionGate = ProjectionGate()
    private let project: Projection

    public convenience init(
        databaseURL: URL, blobDirectory: URL, deviceID: UUID? = nil,
        binding: SyncLibraryBinding? = nil
    ) throws {
        let writer = try SyncDatabase.open(at: databaseURL)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: blobDirectory.path)) ?? []
        try writer.read {
            _ = try SyncDatabase.checkEnrollment(
                $0, role: "client", deviceID: deviceID, binding: binding,
                hasUnboundBlobs: files.contains { $0 != "library-owner" })
        }
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
        try write(pruneObservations)
    }

    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        try writer.read { db in
            try SyncDatabase.checkBinding(db, binding)
            return try body(db)
        }
    }

    private func write<T>(_ body: (Database) throws -> T) throws -> T {
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
        try db.execute(
            sql: "INSERT INTO sync_outbox (sequence, id, payload) VALUES (?, ?, ?)",
            arguments: [sequence, operation.id.uuidString, try SyncDatabase.encode(operation)])
        try db.execute(sql: "UPDATE sync_meta SET sequence = ?", arguments: [sequence])
        try rebuild(db)
        return operation
    }

    /// Enqueues an ordered batch of edits and rebuilds its projection once in the caller's transaction.
    @discardableResult
    public func enqueue(in db: Database, edits: [(captureID: UUID, edit: CaptureEdit)]) throws
        -> [SyncOperation]
    {
        guard ObjectIdentifier(db) == writerIdentity else { throw SyncTransactionError.wrongWriter }
        guard db.isInsideTransaction else { throw SyncTransactionError.requiresTransaction }
        try projectionGate.check()
        try SyncDatabase.checkBinding(db, binding)
        guard !edits.isEmpty else { return [] }
        var predecessors: [UUID: UUID] = [:]
        for pending in try operations(db) {
            predecessors[try SyncDatabase.canonical(db, pending.captureID)] = pending.id
        }
        var sequence = try Int64.fetchOne(db, sql: "SELECT sequence FROM sync_meta")!
        var appended: [SyncOperation] = []
        for (captureID, edit) in edits {
            let id = try SyncDatabase.canonical(db, captureID)
            guard sequence < Int64.max else { throw SyncError.invalidOperation }
            sequence += 1
            let operation = SyncOperation(
                deviceID: deviceID, sequence: sequence,
                captureID: captureID,
                baseRevision: try SyncDatabase.record(db, id: id)?.revision ?? 0,
                predecessorID: predecessors[id], mutation: .edit(edit))
            try SyncDatabase.validate(operation)
            try db.execute(
                sql: "INSERT INTO sync_outbox (sequence, id, payload) VALUES (?, ?, ?)",
                arguments: [sequence, operation.id.uuidString, try SyncDatabase.encode(operation)])
            predecessors[id] = operation.id
            appended.append(operation)
        }
        try db.execute(sql: "UPDATE sync_meta SET sequence = ?", arguments: [sequence])
        try rebuild(db)
        return appended
    }

    /// Export visible content without changing the original device history or pending BLOBs.
    public func contentSnapshotImport(snapshotID: UUID, targetBinding: SyncLibraryBinding) throws
        -> ContentSnapshotImport
    {
        try read { db in
            ContentSnapshotImport(
                snapshotID: snapshotID, targetBinding: targetBinding, sourceDeviceID: deviceID,
                captures: try SyncDatabase.records(db, table: "sync_visible"))
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
            let current = try SyncDatabase.record(db, id: record.id)
            if let current {
                guard sameIdentity(record, current) else { throw SyncError.invalidOperation }
            }
            let observed =
                try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM sync_observed WHERE id = ?)",
                    arguments: [operation.id.uuidString])!
                || operation.sequence <= Int64.fetchOne(
                    db, sql: "SELECT observed_sequence FROM sync_meta")!
            if let current, !observed {
                guard record.revision > current.revision else { throw SyncError.invalidOperation }
                switch operation.mutation {
                case .recapture, .create:
                    guard record.seenCount == Int.max || record.seenCount > current.seenCount else {
                        throw SyncError.invalidOperation
                    }
                    if record.revision - 1 == current.revision {
                        let count = current.seenCount == Int.max ? Int.max : current.seenCount + 1
                        guard record.seenCount == count else { throw SyncError.invalidOperation }
                    }
                case .edit(let edit) where edit.note == nil:
                    if record.revision - 1 == current.revision {
                        guard record.note == current.note,
                            record.noteRevision == current.noteRevision,
                            record.noteOperationID == current.noteOperationID,
                            record.noteConflicts == current.noteConflicts
                        else { throw SyncError.invalidOperation }
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
                record.noteConflicts.contains(where: { $0.operationID == operation.id })
            else { throw SyncError.invalidOperation }
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
        var cursor = oldCursor
        for change in page.changes {
            guard cursor < Int64.max, change.cursor == cursor + 1,
                change.capture.revision == change.cursor
            else {
                throw SyncError.invalidCursor
            }
            cursor = change.cursor
        }
        guard page.cursor == cursor else { throw SyncError.invalidCursor }
    }

    private func commit(_ page: FeedPage, after oldCursor: Int64) throws {
        try validate(page, after: oldCursor)
        try write { db in
            guard try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta") == oldCursor
            else {
                throw SyncError.invalidCursor
            }
            for change in page.changes {
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
            }
            try rebuild(db)
            try db.execute(sql: "UPDATE sync_meta SET cursor = ?", arguments: [page.cursor])
        }
    }

    private func commit(_ baseline: Baseline, after oldCursor: Int64) throws {
        try validate(baseline, after: oldCursor)
        try write { db in
            guard try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta") == oldCursor
            else { throw SyncError.invalidCursor }
            let acceptedSequence = baseline.deviceSequences[deviceID] ?? 0
            try pruneObservations(db)
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
    }

    private func validateLocalChange(_ change: FeedChange, in db: Database) throws {
        if let pending = try operations(db).first(where: { $0.id == change.operationID }) {
            guard pending.captureID == change.requestedCaptureID,
                pending.sequence == change.sequence
            else { throw SyncError.invalidOperation }
            let outcome: SyncReceipt.Outcome =
                change.capture.noteConflicts.contains(where: { $0.operationID == pending.id })
                ? .noteConflict : .accepted
            try validate(
                SyncReceipt(operationID: pending.id, outcome: outcome, capture: change.capture),
                for: pending, in: db)
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

    private func rebuild(_ db: Database) throws {
        let before = try SyncDatabase.records(db, table: "sync_visible")
        try pruneObservations(db)
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

    private func pruneObservations(_ db: Database) throws {
        try db.execute(
            sql: "DELETE FROM sync_observed WHERE id NOT IN (SELECT id FROM sync_outbox)")
    }
}

public enum SyncTransactionError: Error, Equatable, Sendable {
    case wrongWriter, requiresTransaction, projectionFeedback
}

private final class ProjectionGate: @unchecked Sendable {
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
