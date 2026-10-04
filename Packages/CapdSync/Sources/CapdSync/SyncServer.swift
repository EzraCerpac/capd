import Foundation
import GRDB

/// A single-library authority. HTTP access requires an immutable libraryID.
public final class SyncServer: SyncTransport, Sendable {
    private let writer: any DatabaseWriter
    private let binding: SyncLibraryBinding?
    public let blobs: BlobStore
    public let libraryID: UUID?
    public let serviceID: UUID?

    public var reader: any AcceptedCaptureReader {
        ServerCaptureReader(reader: writer, binding: binding)
    }

    public init(
        databaseURL: URL, blobDirectory: URL, libraryID: UUID? = nil, serviceID: UUID? = nil
    ) throws {
        guard (libraryID == nil) == (serviceID == nil) else {
            throw SyncBindingError.bindingRequired
        }
        self.libraryID = libraryID
        self.serviceID = serviceID
        binding = libraryID.flatMap { library in
            serviceID.map { SyncLibraryBinding(libraryID: library, serviceID: $0) }
        }
        try BlobStore.validateExistingOwnership(blobDirectory, binding: binding)
        writer = try SyncDatabase.open(at: databaseURL)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: blobDirectory.path)) ?? []
        _ = try SyncDatabase.prepare(
            writer, role: "server", binding: binding,
            hasUnboundBlobs: files.contains { $0 != "library-owner" })
        blobs = try BlobStore(directory: blobDirectory, binding: binding)
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

    public func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        try apply(operation, validating: { _, _ in })
    }

    func apply(
        _ operation: SyncOperation,
        validating validate: (SyncReceipt, FeedChange?) throws -> Void
    ) throws -> SyncReceipt {
        try write { db in
            if let row = try Row.fetchOne(
                db, sql: "SELECT operation, receipt FROM sync_receipts WHERE id = ?",
                arguments: [operation.id.uuidString])
            {
                let data: Data = row["operation"]
                guard try SyncDatabase.decode(SyncOperation.self, data) == operation else {
                    throw SyncError.operationIDReused
                }
                let receipt = try SyncDatabase.decode(SyncReceipt.self, row["receipt"])
                try validate(receipt, nil)
                return receipt
            }
            try SyncDatabase.validate(operation)
            let previous =
                try Int64.fetchOne(
                    db, sql: "SELECT sequence FROM sync_devices WHERE id = ?",
                    arguments: [operation.deviceID.uuidString]) ?? 0
            guard operation.sequence == previous + 1 else {
                throw SyncError.outOfOrder(expected: previous + 1)
            }
            let id = try SyncDatabase.canonical(db, operation.captureID)
            var base = operation.baseRevision
            var predecessorID = operation.predecessorID
            var precedingSequence = operation.sequence
            while let priorID = predecessorID {
                guard
                    let row = try Row.fetchOne(
                        db,
                        sql: "SELECT operation, receipt FROM sync_receipts WHERE id = ?",
                        arguments: [priorID.uuidString])
                else { throw SyncError.invalidOperation }
                let predecessor = try SyncDatabase.decode(SyncOperation.self, row["operation"])
                let receipt = try SyncDatabase.decode(SyncReceipt.self, row["receipt"])
                guard predecessor.deviceID == operation.deviceID,
                    predecessor.sequence < precedingSequence,
                    try SyncDatabase.canonical(db, predecessor.captureID) == id
                else {
                    throw SyncError.invalidOperation
                }
                // A rating-only predecessor cannot prove that an offline note saw a concurrent edit.
                if let capture = receipt.capture, capture.noteOperationID == predecessor.id {
                    base = max(base, capture.noteRevision)
                    break
                }
                precedingSequence = predecessor.sequence
                predecessorID = predecessor.predecessorID
            }
            let cursor = try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta")! + 1
            var record = try SyncDatabase.record(db, id: id)
            var outcome: SyncReceipt.Outcome = .accepted
            var changed = false
            switch operation.mutation {
            case .create(var incoming):
                if record != nil {
                    outcome = record!.deleted ? .deleted : .alreadyExists
                } else if var existing = try SyncDatabase.matchingRecord(
                    db, source: incoming.source)
                {
                    try SyncDatabase.alias(db, incoming.id, to: existing.id)
                    if existing.deleted {
                        outcome = .deleted
                    } else {
                        existing.revision = cursor
                        if existing.seenCount < Int.max { existing.seenCount += 1 }
                        existing.manualTags = Array(
                            Set(existing.manualTags).union(incoming.manualTags)
                        ).sorted()
                        if incoming.note != nil, incoming.note != existing.note {
                            let edit = CaptureEdit(note: NoteEdit(incoming.note))
                            if try SyncDatabase.edit(
                                &existing, edit, operation: operation, base: 0, server: true)
                            {
                                outcome = .noteConflict
                            }
                        }
                        changed = true
                    }
                    record = existing
                } else {
                    incoming.revision = cursor
                    incoming.noteRevision = incoming.note == nil ? 0 : cursor
                    incoming.noteOperationID = operation.id
                    incoming.manualTags = Array(Set(incoming.manualTags)).sorted()
                    if let blob = incoming.source.blob { _ = try blobs.read(blob) }
                    record = incoming
                    changed = true
                }
            default:
                if var current = record {
                    guard base <= current.revision else { throw SyncError.invalidOperation }
                    if case .restore = operation.mutation {
                        if !current.deleted || operation.baseRevision != current.revision {
                            outcome = .staleRestore
                        } else {
                            if let blob = current.source.blob { _ = try blobs.read(blob) }
                            current.deleted = false
                            changed = true
                        }
                    } else if current.deleted {
                        outcome = .deleted
                    } else {
                        current.revision = cursor
                        switch operation.mutation {
                        case .edit(let edit):
                            if try SyncDatabase.edit(
                                &current, edit, operation: operation, base: base, server: true)
                            {
                                outcome = .noteConflict
                            }
                        case .recapture:
                            if current.seenCount < Int.max { current.seenCount += 1 }
                        case .delete: current.deleted = true
                        default: throw SyncError.invalidOperation
                        }
                        changed = true
                    }
                    if changed { current.revision = cursor }
                    record = current
                } else {
                    outcome = .missing
                }
            }
            let receipt = SyncReceipt(operationID: operation.id, outcome: outcome, capture: record)
            let change =
                changed
                ? record.map {
                    FeedChange(
                        cursor: cursor, operationID: operation.id,
                        deviceID: operation.deviceID, sequence: operation.sequence,
                        requestedCaptureID: operation.captureID, capture: $0)
                } : nil
            try validate(receipt, change)
            if let change, let record {
                try SyncDatabase.save(db, record)
                try db.execute(
                    sql: "INSERT INTO sync_feed (cursor, payload) VALUES (?, ?)",
                    arguments: [cursor, try SyncDatabase.encode(change)])
                try db.execute(sql: "UPDATE sync_meta SET cursor = ?", arguments: [cursor])
            }
            try db.execute(
                sql: "INSERT INTO sync_receipts (id, operation, receipt) VALUES (?, ?, ?)",
                arguments: [
                    operation.id.uuidString, try SyncDatabase.encode(operation),
                    try SyncDatabase.encode(receipt),
                ])
            try db.execute(
                sql: """
                    INSERT INTO sync_devices (id, sequence) VALUES (?, ?)
                    ON CONFLICT(id) DO UPDATE SET sequence = excluded.sequence
                    """, arguments: [operation.deviceID.uuidString, operation.sequence])
            return receipt
        }
    }

    public func changes(after cursor: Int64, limit: Int = 100) throws -> FeedPage {
        try changes(after: cursor, limit: limit) {
            try SyncDatabase.encode(FeedPage(cursor: $0, changes: [])).count
        }
    }

    func changes(
        after cursor: Int64, limit: Int, pageOverhead: (Int64) throws -> Int
    ) throws -> FeedPage {
        try read { db in
            let floor = try Int64.fetchOne(db, sql: "SELECT floor FROM sync_meta")!
            let head = try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta")!
            guard cursor >= 0, cursor <= head, (1...1000).contains(limit) else {
                throw SyncError.invalidCursor
            }
            guard cursor >= floor else { throw SyncError.cursorExpired }
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT cursor, length(payload) AS bytes FROM sync_feed
                    WHERE cursor > ? ORDER BY cursor LIMIT ?
                    """, arguments: [cursor, limit])
            var changes: [FeedChange] = []
            var payloadBytes = 0
            while let row = try rows.next() {
                let nextCursor: Int64 = row["cursor"]
                let overhead = try pageOverhead(nextCursor)
                let remaining =
                    SyncHTTPHandler.maximumBodyBytes - overhead - payloadBytes
                    - (changes.isEmpty ? 0 : 1)
                guard (row["bytes"] as Int) <= remaining else {
                    if changes.isEmpty { throw SyncHTTPError.resourceLimit }
                    break
                }
                let data = try Data.fetchOne(
                    db, sql: "SELECT payload FROM sync_feed WHERE cursor=?", arguments: [nextCursor]
                )!
                let change = try SyncDatabase.decode(FeedChange.self, data)
                let encodedBytes = try SyncDatabase.encode(change).count
                guard encodedBytes <= remaining else {
                    if changes.isEmpty { throw SyncHTTPError.resourceLimit }
                    break
                }
                payloadBytes += encodedBytes + (changes.isEmpty ? 0 : 1)
                changes.append(change)
            }
            return FeedPage(cursor: changes.last?.cursor ?? head, changes: changes)
        }
    }

    public func baseline() throws -> Baseline {
        try read { db in
            let sequences = try Dictionary(
                uniqueKeysWithValues: Row.fetchAll(
                    db,
                    sql: "SELECT id, sequence FROM sync_devices"
                ).map { row in
                    let id: String = row["id"]
                    let sequence: Int64 = row["sequence"]
                    return (UUID(uuidString: id)!, sequence)
                })
            return Baseline(
                cursor: try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta")!,
                captures: try SyncDatabase.records(db), deviceSequences: sequences)
        }
    }

    /// Returns a bounded page pinned to the authority cursor, or just its summary with limit zero.
    public func baselinePage(after: UUID?, limit: Int, expectedCursor: Int64? = nil) throws
        -> Baseline
    {
        guard (0...1000).contains(limit) else { throw SyncError.invalidCursor }
        return try read { db in
            let cursor = try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta")!
            guard expectedCursor == nil || expectedCursor == cursor else {
                throw SyncError.invalidCursor
            }
            let sequences = try Dictionary(
                uniqueKeysWithValues: Row.fetchAll(
                    db, sql: "SELECT id, sequence FROM sync_devices"
                ).map { row in
                    (UUID(uuidString: row["id"] as String)!, row["sequence"] as Int64)
                })
            let captures = try Data.fetchAll(
                db,
                sql: "SELECT payload FROM sync_records WHERE id > ? ORDER BY id LIMIT ?",
                arguments: [after?.uuidString ?? "", limit]
            )
            .map { try SyncDatabase.decode(SharedCapture.self, $0) }
            return Baseline(cursor: cursor, captures: captures, deviceSequences: sequences)
        }
    }

    public func previewContentSnapshotImport(_ snapshot: ContentSnapshotImport) throws
        -> ContentSnapshotImportPreview
    {
        try read { try SnapshotImport.preview($0, snapshot: snapshot, binding: binding) }
    }

    /// Administrative content import. No source-device operation is acknowledged or renumbered.
    public func importContentSnapshot(
        _ snapshot: ContentSnapshotImport, preview: ContentSnapshotImportPreview
    ) throws -> ContentSnapshotImportReceipt {
        try write {
            try SnapshotImport.apply(
                $0, snapshot: snapshot, preview: preview, binding: binding, blobs: blobs)
        }
    }

    public func retainedContentSnapshotImport(_ snapshotID: UUID) throws
        -> RetainedContentSnapshotImport?
    {
        try read { try SnapshotImport.retained($0, id: snapshotID) }
    }

    public func expiredContentSnapshotFeed(_ snapshotID: UUID) throws -> [FeedChange] {
        try read { db in
            guard try db.tableExists("sync_content_snapshot_expired_feed") else { return [] }
            return try Data.fetchAll(
                db,
                sql:
                    "SELECT payload FROM sync_content_snapshot_expired_feed WHERE import_id=? ORDER BY cursor",
                arguments: [snapshotID.uuidString]
            ).map { try SyncDatabase.decode(FeedChange.self, $0) }
        }
    }

    public func expireFeed(through cursor: Int64) throws {
        try write { db in
            let head = try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta")!
            let floor = try Int64.fetchOne(db, sql: "SELECT floor FROM sync_meta")!
            guard cursor >= floor, cursor <= head else { throw SyncError.invalidCursor }
            try db.execute(sql: "DELETE FROM sync_feed WHERE cursor <= ?", arguments: [cursor])
            try db.execute(sql: "UPDATE sync_meta SET floor = ?", arguments: [cursor])
        }
    }

    public func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try read { _ in }
        try blobs.receive(blob, offset: offset, chunk: chunk, final: final)
    }

    public func download(_ blob: BlobReference) throws -> Data {
        try read { _ in }
        return try blobs.read(blob)
    }
}

private struct ServerCaptureReader: AcceptedCaptureReader {
    let reader: any DatabaseReader
    let binding: SyncLibraryBinding?

    func acceptedCaptures() throws -> [SharedCapture] {
        try reader.read { db in
            try SyncDatabase.checkBinding(db, binding)
            return try SyncDatabase.records(db).filter { !$0.deleted }
        }
    }
}

/// Serializes domain values across the boundary without opening a socket.
public struct LoopbackTransport: SyncTransport {
    private let server: SyncServer

    public init(server: SyncServer) { self.server = server }

    private func wire<T: Codable>(_ value: T) throws -> T {
        try SyncDatabase.decode(T.self, SyncDatabase.encode(value))
    }

    public func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        try wire(server.apply(wire(operation)))
    }
    public func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        try wire(server.changes(after: cursor, limit: limit))
    }
    public func baseline() throws -> Baseline { try wire(server.baseline()) }
    public func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        try server.upload(wire(blob), offset: offset, chunk: chunk, final: final)
    }
    public func download(_ blob: BlobReference) throws -> Data { try server.download(wire(blob)) }
}
