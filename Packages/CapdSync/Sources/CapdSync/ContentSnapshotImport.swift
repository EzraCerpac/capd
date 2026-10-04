import Foundation
import GRDB

public enum ContentSnapshotCountPolicy: String, Codable, Equatable, Sendable {
    case maximumKnownLowerBound
}

/// Content preservation only; the source's original operation history remains a separate archive.
public struct ContentSnapshotImport: Codable, Equatable, Sendable {
    public let version: Int
    public let snapshotID: UUID
    public let targetBinding: SyncLibraryBinding
    public let sourceDeviceID: UUID
    public let captures: [SharedCapture]
    public let countPolicy: ContentSnapshotCountPolicy

    public init(
        snapshotID: UUID, targetBinding: SyncLibraryBinding, sourceDeviceID: UUID,
        captures: [SharedCapture]
    ) {
        version = 1
        self.snapshotID = snapshotID
        self.targetBinding = targetBinding
        self.sourceDeviceID = sourceDeviceID
        self.captures = captures.sorted { $0.id.uuidString < $1.id.uuidString }
        countPolicy = .maximumKnownLowerBound
    }
}

public enum ContentSnapshotField: String, Codable, Equatable, Sendable {
    case source, createdAt, deleted, note, noteConflicts, rating, manualTags, generated, metadata
    case seenCount, unknownFields
}

public struct ContentSnapshotItemPreview: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable { case insert, merge, preserveTombstone }
    public let source: SharedCapture
    public let authority: SharedCapture?
    public let canonicalCaptureID: UUID
    public let disposition: Disposition
    public let differingFields: [ContentSnapshotField]
    public let proposedSeenCount: Int
    public let countIsExact: Bool
}

/// Pass this reviewed state back to import; intervening authority changes invalidate it.
public struct ContentSnapshotImportPreview: Codable, Equatable, Sendable {
    public let snapshotID: UUID
    public let digest: String
    public let targetBinding: SyncLibraryBinding
    public let sourceDeviceID: UUID
    public let authorityCursor: Int64
    public let authorityFloor: Int64
    public let feedRowsToExpire: Int
    public let countPolicy: ContentSnapshotCountPolicy
    public let items: [ContentSnapshotItemPreview]
}

public struct ContentSnapshotImportedNote: Codable, Equatable, Sendable {
    public let sourceOperationID: UUID
    public let importedVariantID: UUID
    public let value: String?
}

/// These are new import receipts, never acknowledgements of the source device's pending operations.
public struct ContentSnapshotItemReceipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let sourceCaptureID: UUID
    public let canonicalCaptureID: UUID
    public let importedNotes: [ContentSnapshotImportedNote]
}

public struct ContentSnapshotImportReceipt: Codable, Equatable, Sendable {
    public let id: UUID
    public let snapshotID: UUID
    public let digest: String
    public let targetBinding: SyncLibraryBinding
    public let sourceDeviceID: UUID
    public let authorityCursor: Int64
    public let countPolicy: ContentSnapshotCountPolicy
    public let items: [ContentSnapshotItemReceipt]
}

public struct RetainedContentSnapshotImport: Codable, Equatable, Sendable {
    public let snapshot: ContentSnapshotImport
    public let preview: ContentSnapshotImportPreview
    public let receipt: ContentSnapshotImportReceipt
}

public enum ContentSnapshotImportError: Error, Equatable, Sendable {
    case invalidSnapshot, snapshotIDReused, stalePreview, identityCollision
}

enum SnapshotImport {
    static func retained(_ db: Database, id: UUID) throws -> RetainedContentSnapshotImport? {
        guard try db.tableExists("sync_content_snapshot_imports"),
            let data = try Data.fetchOne(
                db, sql: "SELECT payload FROM sync_content_snapshot_imports WHERE id = ?",
                arguments: [id.uuidString])
        else { return nil }
        return try SyncDatabase.decode(RetainedContentSnapshotImport.self, data)
    }

    static func preview(
        _ db: Database, snapshot: ContentSnapshotImport, binding: SyncLibraryBinding?
    ) throws -> ContentSnapshotImportPreview {
        try validate(snapshot, binding: binding)
        if let prior = try retained(db, id: snapshot.snapshotID) {
            guard prior.snapshot == snapshot else {
                throw ContentSnapshotImportError.snapshotIDReused
            }
            return prior.preview
        }
        var records = Dictionary(
            uniqueKeysWithValues: try SyncDatabase.records(db).map { ($0.id, $0) })
        var items: [ContentSnapshotItemPreview] = []
        for incoming in snapshot.captures {
            let requested = try SyncDatabase.canonical(db, incoming.id)
            let existing: SharedCapture?
            if let match = records[requested] {
                guard sameIdentity(match.source, incoming.source) else {
                    throw ContentSnapshotImportError.identityCollision
                }
                existing = match
            } else if let hash = incoming.source.contentHash,
                let match = records.values.first(where: { $0.source.contentHash == hash })
            {
                guard sameIdentity(match.source, incoming.source) else {
                    throw ContentSnapshotImportError.identityCollision
                }
                existing = match
            } else {
                existing = nil
            }
            let canonical = existing?.id ?? incoming.id
            let tombstone = existing?.deleted == true || incoming.deleted
            let count =
                existing.map { tombstone ? $0.seenCount : max($0.seenCount, incoming.seenCount) }
                ?? incoming.seenCount
            items.append(
                ContentSnapshotItemPreview(
                    source: incoming, authority: existing, canonicalCaptureID: canonical,
                    disposition: existing == nil
                        ? .insert : (tombstone ? .preserveTombstone : .merge),
                    differingFields: existing.map { differences($0, incoming) } ?? [],
                    proposedSeenCount: count, countIsExact: false))
            if var current = existing {
                if !tombstone {
                    current.seenCount = count
                    current.manualTags = Array(Set(current.manualTags).union(incoming.manualTags))
                        .sorted()
                    for variant in incomingNotes(incoming)
                    where !knownNotes(current).contains(variant.value) {
                        if current.noteConflicts.isEmpty {
                            current.noteConflicts.append(
                                NoteVariant(
                                    operationID: current.noteOperationID, value: current.note))
                        }
                        current.noteConflicts.append(variant)
                    }
                }
                records[canonical] = current
            } else {
                records[canonical] = incoming
            }
        }
        let bytes = try SyncDatabase.encode(snapshot)
        guard bytes.count <= SyncHTTPHandler.maximumBodyBytes else {
            throw ContentSnapshotImportError.invalidSnapshot
        }
        return ContentSnapshotImportPreview(
            snapshotID: snapshot.snapshotID, digest: BlobReference(data: bytes).digest,
            targetBinding: snapshot.targetBinding, sourceDeviceID: snapshot.sourceDeviceID,
            authorityCursor: try Int64.fetchOne(
                db, sql: "SELECT cursor FROM sync_meta WHERE id=1")!,
            authorityFloor: try Int64.fetchOne(db, sql: "SELECT floor FROM sync_meta WHERE id=1")!,
            feedRowsToExpire: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_feed")!,
            countPolicy: snapshot.countPolicy, items: items)
    }

    static func apply(
        _ db: Database, snapshot: ContentSnapshotImport, preview: ContentSnapshotImportPreview,
        binding: SyncLibraryBinding?, blobs: BlobStore
    ) throws -> ContentSnapshotImportReceipt {
        try validate(snapshot, binding: binding)
        if let prior = try retained(db, id: snapshot.snapshotID) {
            guard prior.snapshot == snapshot else {
                throw ContentSnapshotImportError.snapshotIDReused
            }
            return prior.receipt
        }
        guard try Self.preview(db, snapshot: snapshot, binding: binding) == preview,
            preview.authorityCursor < Int64.max
        else { throw ContentSnapshotImportError.stalePreview }
        for capture in snapshot.captures {
            if let blob = capture.source.blob { _ = try blobs.read(blob) }
        }
        try db.execute(
            sql: """
                CREATE TABLE IF NOT EXISTS sync_content_snapshot_imports (
                    id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS sync_content_snapshot_expired_feed (
                    import_id TEXT NOT NULL, cursor INTEGER NOT NULL, payload BLOB NOT NULL,
                    PRIMARY KEY (import_id, cursor));
                """)
        let cursor = preview.authorityCursor + 1
        var receipts: [ContentSnapshotItemReceipt] = []
        for item in preview.items {
            let incoming = item.source
            let receiptID = UUID()
            var importedNotes: [ContentSnapshotImportedNote] = []
            if var current = try SyncDatabase.record(db, id: item.canonicalCaptureID) {
                if item.disposition == .merge {
                    current.seenCount = max(current.seenCount, incoming.seenCount)
                    current.manualTags = Array(Set(current.manualTags).union(incoming.manualTags))
                        .sorted()
                    for variant in incomingNotes(incoming)
                    where !knownNotes(current).contains(variant.value) {
                        let newID = UUID()
                        if current.noteConflicts.isEmpty {
                            current.noteConflicts.append(
                                NoteVariant(
                                    operationID: current.noteOperationID, value: current.note))
                        }
                        current.noteConflicts.append(
                            NoteVariant(
                                operationID: newID, value: variant.value,
                                unknownFields: variant.unknownFields))
                        importedNotes.append(
                            ContentSnapshotImportedNote(
                                sourceOperationID: variant.operationID, importedVariantID: newID,
                                value: variant.value))
                    }
                    if !importedNotes.isEmpty { current.noteRevision = cursor }
                    current.revision = cursor
                    try SyncDatabase.save(db, current)
                }
            } else {
                var imported = incoming
                imported.revision = cursor
                imported.noteRevision =
                    imported.note == nil && imported.noteConflicts.isEmpty ? 0 : cursor
                imported.noteOperationID = receiptID
                importedNotes.append(
                    ContentSnapshotImportedNote(
                        sourceOperationID: incoming.noteOperationID, importedVariantID: receiptID,
                        value: incoming.note))
                imported.noteConflicts = incoming.noteConflicts.map { variant in
                    let id = UUID()
                    importedNotes.append(
                        ContentSnapshotImportedNote(
                            sourceOperationID: variant.operationID, importedVariantID: id,
                            value: variant.value))
                    return NoteVariant(
                        operationID: id, value: variant.value, unknownFields: variant.unknownFields)
                }
                imported.manualTags = Array(Set(imported.manualTags)).sorted()
                try SyncDatabase.save(db, imported)
            }
            if incoming.id != item.canonicalCaptureID {
                try SyncDatabase.alias(db, incoming.id, to: item.canonicalCaptureID)
            }
            receipts.append(
                ContentSnapshotItemReceipt(
                    id: receiptID, sourceCaptureID: incoming.id,
                    canonicalCaptureID: item.canonicalCaptureID,
                    importedNotes: importedNotes))
        }
        try db.execute(
            sql:
                "INSERT INTO sync_content_snapshot_expired_feed SELECT ?, cursor, payload FROM sync_feed",
            arguments: [snapshot.snapshotID.uuidString])
        try db.execute(sql: "DELETE FROM sync_feed")
        try db.execute(
            sql: "UPDATE sync_meta SET cursor=?,floor=? WHERE id=1", arguments: [cursor, cursor])
        let receipt = ContentSnapshotImportReceipt(
            id: UUID(), snapshotID: snapshot.snapshotID, digest: preview.digest,
            targetBinding: snapshot.targetBinding, sourceDeviceID: snapshot.sourceDeviceID,
            authorityCursor: cursor, countPolicy: snapshot.countPolicy, items: receipts)
        let retained = RetainedContentSnapshotImport(
            snapshot: snapshot, preview: preview, receipt: receipt)
        try db.execute(
            sql: "INSERT INTO sync_content_snapshot_imports (id,payload) VALUES (?,?)",
            arguments: [snapshot.snapshotID.uuidString, try SyncDatabase.encode(retained)])
        return receipt
    }

    private static func validate(_ snapshot: ContentSnapshotImport, binding: SyncLibraryBinding?)
        throws
    {
        guard snapshot.targetBinding == binding else { throw SyncBindingError.mismatch }
        guard snapshot.version == 1, !snapshot.captures.isEmpty,
            Set(snapshot.captures.map(\.id)).count == snapshot.captures.count,
            snapshot.countPolicy == .maximumKnownLowerBound
        else { throw ContentSnapshotImportError.invalidSnapshot }
        for record in snapshot.captures {
            guard record.seenCount >= 1, record.revision >= 0, record.noteRevision >= 0,
                record.noteRevision <= record.revision
            else { throw ContentSnapshotImportError.invalidSnapshot }
            var shape = record
            shape.revision = 0
            shape.noteRevision = 0
            shape.noteConflicts = []
            shape.deleted = false
            shape.seenCount = 1
            shape.generated.taggingProcessed = nil
            shape.generated.taggingInputFingerprint = nil
            try SyncDatabase.validate(
                SyncOperation(
                    deviceID: snapshot.sourceDeviceID, sequence: 1, captureID: shape.id,
                    baseRevision: 0,
                    mutation: .create(shape)))
        }
    }

    private static func sameIdentity(_ lhs: CaptureSource, _ rhs: CaptureSource) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        if let hash = lhs.contentHash, hash == rhs.contentHash {
            return lhs.kind != .image || lhs.blob == rhs.blob
        }
        return lhs.contentHash == rhs.contentHash && lhs.url == rhs.url && lhs.blob == rhs.blob
            && (lhs.kind != .text || lhs.selection == rhs.selection)
    }

    private static func incomingNotes(_ record: SharedCapture) -> [NoteVariant] {
        [NoteVariant(operationID: record.noteOperationID, value: record.note)]
            + record.noteConflicts
    }

    private static func knownNotes(_ record: SharedCapture) -> [String?] {
        [record.note] + record.noteConflicts.map(\.value)
    }

    private static func differences(_ lhs: SharedCapture, _ rhs: SharedCapture)
        -> [ContentSnapshotField]
    {
        var fields: [ContentSnapshotField] = []
        if lhs.source != rhs.source { fields.append(.source) }
        if lhs.createdAt != rhs.createdAt { fields.append(.createdAt) }
        if lhs.deleted != rhs.deleted { fields.append(.deleted) }
        if lhs.note != rhs.note { fields.append(.note) }
        if lhs.noteConflicts != rhs.noteConflicts { fields.append(.noteConflicts) }
        if lhs.rating != rhs.rating { fields.append(.rating) }
        if lhs.manualTags != rhs.manualTags { fields.append(.manualTags) }
        if lhs.generated != rhs.generated { fields.append(.generated) }
        if lhs.metadata != rhs.metadata { fields.append(.metadata) }
        if lhs.seenCount != rhs.seenCount { fields.append(.seenCount) }
        if lhs.unknownFields != rhs.unknownFields { fields.append(.unknownFields) }
        return fields
    }
}
