import Foundation
import GRDB

enum SyncDatabase {
    static func open(at url: URL) throws -> DatabasePool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        return try DatabasePool(path: url.path, configuration: configuration)
    }

    static func prepare(
        _ writer: any DatabaseWriter, role: String, deviceID: UUID? = nil,
        binding: SyncLibraryBinding? = nil, hasUnboundBlobs: Bool = false,
        prepareProjection: @Sendable (Database) throws -> Void = { _ in }
    ) throws
        -> UUID?
    {
        try writer.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS sync_meta (
                        id INTEGER PRIMARY KEY CHECK (id = 1), role TEXT NOT NULL,
                        device TEXT, sequence INTEGER NOT NULL DEFAULT 0,
                        cursor INTEGER NOT NULL DEFAULT 0, floor INTEGER NOT NULL DEFAULT 0,
                        observed_sequence INTEGER NOT NULL DEFAULT 0);
                    CREATE TABLE IF NOT EXISTS sync_records (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                    CREATE TABLE IF NOT EXISTS sync_aliases (id TEXT PRIMARY KEY, canonical TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS sync_receipts (
                        id TEXT PRIMARY KEY, operation BLOB NOT NULL, receipt BLOB NOT NULL);
                    CREATE TABLE IF NOT EXISTS sync_devices (id TEXT PRIMARY KEY, sequence INTEGER NOT NULL);
                    CREATE TABLE IF NOT EXISTS sync_feed (
                        cursor INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL);
                    CREATE TABLE IF NOT EXISTS sync_outbox (
                        sequence INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, payload BLOB NOT NULL);
                    CREATE TABLE IF NOT EXISTS sync_visible (
                        local_id INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, payload BLOB NOT NULL);
                    CREATE TABLE IF NOT EXISTS sync_rejections (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                    CREATE TABLE IF NOT EXISTS sync_observed (id TEXT PRIMARY KEY);
                    CREATE TABLE IF NOT EXISTS sync_binding (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL);
                    """)
            let storedBinding = try checkEnrollment(
                db, role: role, deviceID: deviceID, binding: binding,
                hasUnboundBlobs: hasUnboundBlobs)
            if binding != nil && storedBinding == nil {
                if let binding {
                    try db.execute(
                        sql: "INSERT INTO sync_binding (id, payload) VALUES (1, ?)",
                        arguments: [try encode(binding)])
                }

            }
            if let row = try Row.fetchOne(db, sql: "SELECT role, device FROM sync_meta") {
                let storedDevice: String? = row["device"]
                let storedID = storedDevice.flatMap(UUID.init(uuidString:))
                try prepareProjection(db)
                try checkPreparedIdentity(db, role: role, device: storedID, binding: binding)
                return storedID
            } else {
                let allocatedID = role == "client" ? (deviceID ?? UUID()) : nil
                try db.execute(
                    sql: "INSERT INTO sync_meta (id, role, device) VALUES (1, ?, ?)",
                    arguments: [role, allocatedID?.uuidString])
                try prepareProjection(db)
                try checkPreparedIdentity(db, role: role, device: allocatedID, binding: binding)
                return allocatedID
            }
        }
    }

    static func checkEnrollment(
        _ db: Database, role: String, deviceID: UUID?, binding: SyncLibraryBinding?,
        hasUnboundBlobs: Bool
    ) throws -> SyncLibraryBinding? {
        let existingTables = try String.fetchSet(
            db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        let storedBinding =
            try existingTables.contains("sync_binding")
            ? Data.fetchOne(db, sql: "SELECT payload FROM sync_binding")
                .map { try decode(SyncLibraryBinding.self, $0) } : nil
        guard storedBinding == nil || storedBinding == binding else {
            throw SyncBindingError.mismatch
        }
        if binding != nil && storedBinding == nil {
            let usedMeta =
                try existingTables.contains("sync_meta")
                && Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM sync_meta WHERE sequence != 0 OR cursor != 0 OR floor != 0 OR observed_sequence != 0"
                )! > 0
            let tables = [
                "sync_records", "sync_aliases", "sync_receipts", "sync_devices", "sync_feed",
                "sync_outbox", "sync_visible", "sync_rejections", "sync_observed",
            ]
            let usedRows = try tables.contains {
                try existingTables.contains($0)
                    && Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")! > 0
            }
            guard !usedMeta, !usedRows, !hasUnboundBlobs else {
                throw SyncBindingError.enrollmentRequiresEmptyLibrary
            }
        }
        if existingTables.contains("sync_meta"),
            let row = try Row.fetchOne(db, sql: "SELECT role, device FROM sync_meta")
        {
            let storedRole: String = row["role"]
            let storedDevice: String? = row["device"]
            guard storedRole == role else { throw SyncError.invalidOperation }
            if let deviceID {
                guard storedDevice == deviceID.uuidString else { throw SyncError.wrongDevice }
            } else if role == "server" {
                guard storedDevice == nil else { throw SyncError.wrongDevice }
            }
            guard role != "client" || storedDevice.flatMap(UUID.init(uuidString:)) != nil else {
                throw SyncError.wrongDevice
            }
        }
        return storedBinding
    }

    private static func checkPreparedIdentity(
        _ db: Database, role: String, device: UUID?, binding: SyncLibraryBinding?
    ) throws {
        try checkBinding(db, binding)
        guard
            let row = try Row.fetchOne(db, sql: "SELECT role, device FROM sync_meta WHERE id = 1"),
            (row["role"] as String) == role
        else { throw SyncError.invalidOperation }
        guard (row["device"] as String?) == device?.uuidString else { throw SyncError.wrongDevice }
    }

    static func checkBinding(_ db: Database, _ binding: SyncLibraryBinding?) throws {
        let stored = try Data.fetchOne(db, sql: "SELECT payload FROM sync_binding")
            .map { try decode(SyncLibraryBinding.self, $0) }
        guard stored == binding else { throw SyncBindingError.mismatch }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    static func record(_ db: Database, id: UUID, table: String = "sync_records") throws
        -> SharedCapture?
    {
        guard
            let data = try Data.fetchOne(
                db, sql: "SELECT payload FROM \(table) WHERE id = ?",
                arguments: [id.uuidString])
        else { return nil }
        return try decode(SharedCapture.self, data)
    }

    static func records(_ db: Database, table: String = "sync_records") throws -> [SharedCapture] {
        try Data.fetchAll(db, sql: "SELECT payload FROM \(table) ORDER BY id")
            .map { try decode(SharedCapture.self, $0) }
    }

    static func save(_ db: Database, _ record: SharedCapture, table: String = "sync_records") throws
    {
        try db.execute(
            sql: """
                INSERT INTO \(table) (id, payload) VALUES (?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """, arguments: [record.id.uuidString, try encode(record)])
    }

    static func canonical(_ db: Database, _ id: UUID) throws -> UUID {
        guard
            let value = try String.fetchOne(
                db, sql: "SELECT canonical FROM sync_aliases WHERE id = ?",
                arguments: [id.uuidString]), let uuid = UUID(uuidString: value)
        else { return id }
        return uuid
    }

    static func alias(_ db: Database, _ id: UUID, to canonical: UUID) throws {
        guard id != canonical else { return }
        try db.execute(
            sql: """
                INSERT INTO sync_aliases (id, canonical) VALUES (?, ?)
                ON CONFLICT(id) DO UPDATE SET canonical = excluded.canonical
                """, arguments: [id.uuidString, canonical.uuidString])
    }

    static func validate(_ operation: SyncOperation) throws {
        guard operation.sequence > 0, operation.baseRevision >= 0 else {
            throw SyncError.invalidOperation
        }
        switch operation.mutation {
        case .create(let record):
            guard record.id == operation.captureID, record.revision == 0, !record.deleted,
                record.seenCount == 1, record.noteConflicts.isEmpty,
                record.noteRevision == 0, (1...5).contains(record.rating),
                record.source.kind != .image || record.source.blob != nil
            else {
                throw SyncError.invalidOperation
            }
            try record.source.blob?.validate()
            try record.generated.validateTaggingProcessing()
        case .edit(let edit):
            guard edit.unknownFields.isEmpty, edit.note?.unknownFields.isEmpty ?? true,
                edit.metadata?.unknownFields.isEmpty ?? true,
                edit.sourceContent?.unknownFields.isEmpty ?? true,
                edit.generatedPatch?.unknownFields.isEmpty ?? true,
                edit.generated == nil || edit.generatedPatch == nil
            else { throw SyncError.invalidOperation }
            try edit.generated?.validateTaggingProcessing()
            if case .processed(let fingerprint) = edit.generatedPatch?.taggingProcessing {
                try validateTaggingFingerprint(fingerprint)
            }
            if let rating = edit.rating, !(1...5).contains(rating) {
                throw SyncError.invalidOperation
            }
        default: break
        }
    }

    static func edit(
        _ record: inout SharedCapture, _ edit: CaptureEdit,
        operation: SyncOperation, base: Int64, server: Bool
    ) throws -> Bool {
        var conflict = false
        if let note = edit.note {
            let known = Set(record.noteConflicts.map(\.operationID))
            if !note.resolving.isEmpty, base >= record.noteRevision, Set(note.resolving) == known {
                record.noteConflicts = []
            }
            if server && (base < record.noteRevision || !record.noteConflicts.isEmpty) {
                if note.value != record.note,
                    !record.noteConflicts.contains(where: { $0.value == note.value })
                {
                    if record.noteConflicts.isEmpty {
                        record.noteConflicts.append(
                            NoteVariant(operationID: record.noteOperationID, value: record.note))
                    }
                    record.noteConflicts.append(
                        NoteVariant(operationID: operation.id, value: note.value))
                    record.noteRevision = record.revision
                    conflict = true
                } else if record.noteConflicts.isEmpty {
                    // The coalesced receipt must still prove causality for its queued successor.
                    record.noteOperationID = operation.id
                }
            } else {
                record.note = note.value
                record.noteOperationID = operation.id
                record.noteRevision = record.revision
            }
        }
        if let rating = edit.rating { record.rating = rating }
        record.manualTags = Array(
            Set(record.manualTags).union(edit.addTags).subtracting(edit.removeTags)
        ).sorted()
        if var generated = edit.generated {
            if !generated.hasTaggingProcessing {
                generated.taggingProcessed = record.generated.taggingProcessed
                generated.taggingInputFingerprint = record.generated.taggingInputFingerprint
            }
            generated.unknownFields = record.generated.unknownFields.merging(
                generated.unknownFields
            ) { _, new in new }
            record.generated = generated
        }
        if let patch = edit.metadata,
            patch.updatedAt != nil || patch.lastSeenAt != nil || patch.reminder != nil
        {
            var metadata = record.metadata ?? CaptureMetadata()
            if let date = patch.updatedAt { metadata.updatedAt = date }
            if let date = patch.lastSeenAt { metadata.lastSeenAt = date }
            if let reminder = patch.reminder {
                switch reminder {
                case .set(let date): metadata.reminderAt = date
                case .clear: metadata.reminderAt = nil
                }
            }
            record.metadata = metadata
        }
        if let patch = edit.sourceContent {
            if record.source.title?.isEmpty ?? true, let title = patch.title, !title.isEmpty {
                record.source.title = title
            }
            if record.source.selection?.isEmpty ?? true, let selection = patch.selection,
                !selection.isEmpty
            {
                record.source.selection = selection
            }
        }
        if let patch = edit.generatedPatch {
            if let body = patch.body {
                switch body {
                case .set(let value): record.generated.body = value
                case .clear: record.generated.body = nil
                }
            }
            if let ocr = patch.ocrText {
                switch ocr {
                case .set(let value): record.generated.ocrText = value
                case .clear: record.generated.ocrText = nil
                }
            }
            if let tags = patch.tags { record.generated.tags = tags }
            if let processing = patch.taggingProcessing {
                switch processing {
                case .processed(let fingerprint):
                    record.generated.taggingProcessed = true
                    record.generated.taggingInputFingerprint = fingerprint
                case .pending:
                    record.generated.taggingProcessed = false
                    record.generated.taggingInputFingerprint = nil
                }
            }
        }
        return conflict
    }
}
