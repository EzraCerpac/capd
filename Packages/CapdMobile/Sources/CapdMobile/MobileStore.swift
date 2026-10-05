import CapdSync
import Foundation
import GRDB

public final class MobileStore: Sendable {
    static let pullPageBudget = 100
    private let database: DatabasePool
    private let client: SyncClient
    public var deviceID: UUID { client.deviceID }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        database = try DatabasePool(path: url.path, configuration: configuration)
        try database.read { db in
            guard try !db.tableExists("pendingCaptures") else { throw SyncError.invalidOperation }
        }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("mobile-shared-projection-v1") { db in
            try db.create(table: MobileCapture.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("localID")
                table.column("id", .text).notNull().unique()
                table.column("kind", .text).notNull()
                table.column("url", .text)
                table.column("title", .text).notNull()
                table.column("selection", .text).notNull()
                table.column("note", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("manualTags", .text).notNull()
                table.column("generatedTags", .text).notNull()
                table.column("body", .text)
                table.column("ocrText", .text)
                table.column("noteConflicts", .text).notNull()
                table.column("seenCount", .integer).notNull()
            }
            try db.create(virtualTable: "mobile_captures_fts", using: FTS5()) { table in
                table.synchronize(withTable: MobileCapture.databaseTableName)
                table.tokenizer = .porter(wrapping: .unicode61(diacritics: .remove))
                for name in [
                    "title", "selection", "note", "manualTags", "generatedTags", "body", "ocrText",
                ] {
                    table.column(name)
                }
            }
        }
        migrator.registerMigration("mobile-observed-revision-v2") { db in
            try db.alter(table: MobileCapture.databaseTableName) { table in
                table.add(column: "revision", .integer).notNull().defaults(to: 0)
            }
            if try db.tableExists("sync_visible") {
                try db.execute(
                    sql: """
                        UPDATE mobile_captures SET revision = COALESCE((
                            SELECT json_extract(CAST(payload AS TEXT), '$.revision')
                            FROM sync_visible WHERE sync_visible.id = mobile_captures.id
                        ), 0)
                        """)
            }
        }
        migrator.registerMigration("mobile-original-metadata-v3") { db in
            try db.alter(table: MobileCapture.databaseTableName) { table in
                table.add(column: "metadata", .text)
                table.add(column: "createdAtReferenceSeconds", .double)
            }
            if try db.tableExists("sync_visible") {
                try db.execute(
                    sql: """
                        UPDATE mobile_captures SET
                            metadata = (SELECT json_extract(CAST(payload AS TEXT), '$.metadata')
                                        FROM sync_visible WHERE sync_visible.id = mobile_captures.id),
                            createdAtReferenceSeconds = (SELECT json_extract(CAST(payload AS TEXT), '$.createdAt')
                                                         FROM sync_visible WHERE sync_visible.id = mobile_captures.id)
                        """)
            }
        }
        try migrator.migrate(database)
        client = try SyncClient(
            writer: database,
            blobs: BlobStore(
                directory: url.deletingLastPathComponent().appendingPathComponent("assets")),
            project: Self.project)
    }

    public func contentSnapshotImport(snapshotID: UUID, targetBinding: SyncLibraryBinding) throws
        -> ContentSnapshotImport
    {
        try client.contentSnapshotImport(snapshotID: snapshotID, targetBinding: targetBinding)
    }

    @discardableResult
    public func save(_ capture: MobileCapture) throws -> UUID {
        let hash: String
        if let raw = capture.url, let url = URL(string: raw) {
            hash = CaptureFingerprint.contentHash(for: url)
        } else {
            hash = CaptureFingerprint.contentHash(for: Data(capture.selection.utf8))
        }
        var record = SharedCapture(
            id: capture.id,
            source: CaptureSource(
                kind: capture.kind, contentHash: hash, url: capture.url,
                host: capture.url.flatMap(URL.init(string:))?.host,
                title: capture.title, selection: capture.selection),
            createdAt: capture.createdAt, note: capture.note.isEmpty ? nil : capture.note,
            metadata: capture.metadata)
        record.manualTags = capture.manualTags
        return try enqueue(captureID: record.id, mutation: .create(record)) { db in
            try MobileCaptureSaveValidation.validate(record, in: db)
        }
    }

    @discardableResult
    private func enqueue(
        captureID: UUID, mutation: CaptureMutation, baseRevision: Int64? = nil,
        validating: ((Database) throws -> Void)? = nil
    )
        throws -> UUID
    {
        return try database.write { db in
            try validating?(db)
            let operation = try client.enqueue(
                in: db, captureID: captureID, mutation: mutation, baseRevision: baseRevision)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            // Enrollment identifiers have fixed-width UUID encodings, including before enrollment.
            let envelope = SyncHTTPEnvelope(
                expectedServiceID: deviceID, expectedLibraryID: deviceID,
                expectedDeviceID: deviceID, action: .apply(operation))
            guard try encoder.encode(envelope).count <= SyncHTTPHandler.maximumBodyBytes else {
                throw CaptureValidationError.tooLarge
            }
            if case .delete = mutation {
                return operation.id
            }
            do {
                try client.validateResponseBudget(in: db, captureID: captureID)
            } catch SyncHTTPError.resourceLimit {
                throw CaptureValidationError.tooLarge
            }
            return operation.id
        }
    }

    @discardableResult
    public func update(id: UUID, note: String, tags: [String], resolving: [UUID] = []) throws
        -> UUID?
    {
        guard let current = try capture(id: id) else { throw SyncError.invalidOperation }
        return try update(current, note: note, tags: tags, resolving: resolving)
    }

    @discardableResult
    public func update(
        _ observed: MobileCapture, note: String, tags: [String], resolving: [UUID] = []
    ) throws -> UUID? {
        let previous = Set(observed.manualTags)
        let next = Set(tags)
        let noteChanged = note != observed.note || !resolving.isEmpty
        guard noteChanged || previous != next else { return nil }
        let edit = CaptureEdit(
            note: noteChanged ? NoteEdit(note.isEmpty ? nil : note, resolving: resolving) : nil,
            addTags: Array(next.subtracting(previous)).sorted(),
            removeTags: Array(previous.subtracting(next)).sorted())
        return try enqueue(
            captureID: observed.id, mutation: .edit(edit), baseRevision: observed.revision
        )
    }

    public func delete(id: UUID) throws { try enqueue(captureID: id, mutation: .delete) }

    public func capture(id: UUID) throws -> MobileCapture? {
        try database.read { db in
            let alias = try String.fetchOne(
                db, sql: "SELECT canonical FROM sync_aliases WHERE id = ?",
                arguments: [id.uuidString])
            let canonical = alias.flatMap(UUID.init(uuidString:)) ?? id
            return try MobileCapture.filter(Column("id") == canonical.uuidString).fetchOne(db)
        }
    }

    public func search(_ query: String = "") throws -> [MobileCapture] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.read { db in
            guard !value.isEmpty else {
                return try MobileCapture.order(Column("createdAt").desc, Column("localID").desc)
                    .fetchAll(db)
            }
            let literal =
                "instr(lower(title || char(10) || coalesce(url, '') || char(10) || selection || char(10) || note), lower(?)) > 0"
            if let pattern = FTS5Pattern(matchingAllPrefixesIn: value) {
                return try MobileCapture.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM mobile_captures WHERE localID IN (
                            SELECT rowid FROM mobile_captures_fts WHERE mobile_captures_fts MATCH ?
                        ) OR \(literal) ORDER BY createdAt DESC, localID DESC
                        """, arguments: [pattern, value])
            }
            return try MobileCapture.fetchAll(
                db,
                sql:
                    "SELECT * FROM mobile_captures WHERE \(literal) ORDER BY createdAt DESC, localID DESC",
                arguments: [value])
        }
    }

    public func pending() throws -> [SyncOperation] { try client.pendingOperations() }
    public func rejectedWork() throws -> [RejectedWork] { try client.rejectedWork() }

    /// A lightweight revision of committed local and synchronized library work.
    public func libraryRevision() throws -> MobileLibraryRevision {
        try database.read(Self.libraryRevision)
    }

    func syncSnapshot(previousRevision: MobileLibraryRevision?, previousConflictCount: Int) throws
        -> (revision: MobileLibraryRevision, conflictCount: Int)
    {
        try database.read { db in
            let revision = try Self.libraryRevision(db)
            let conflicts =
                revision == previousRevision
                ? previousConflictCount
                : try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COUNT(*) FROM mobile_captures WHERE json_array_length(noteConflicts) > 0"
                )!
            return (revision, conflicts)
        }
    }

    private static func libraryRevision(_ db: Database) throws -> MobileLibraryRevision {
        guard
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT cursor, sequence,
                        (SELECT COUNT(*) FROM sync_outbox) AS pendingChanges,
                        (SELECT COUNT(*) FROM sync_rejections) AS rejectedChanges
                    FROM sync_meta WHERE id = 1
                    """)
        else { throw SyncError.invalidOperation }
        return MobileLibraryRevision(
            cursor: row["cursor"], sequence: row["sequence"],
            pendingChanges: row["pendingChanges"], rejectedChanges: row["rejectedChanges"])
    }

    public func pendingCaptureIDs() throws -> Set<UUID> {
        let operations = try pending()
        return try database.read { db in
            try Set(
                operations.map { operation in
                    let alias = try String.fetchOne(
                        db, sql: "SELECT canonical FROM sync_aliases WHERE id = ?",
                        arguments: [operation.captureID.uuidString])
                    return alias.flatMap(UUID.init(uuidString:)) ?? operation.captureID
                })
        }
    }

    @discardableResult
    public func push(to transport: any SyncTransport) throws -> [SyncReceipt] {
        try client.push(to: transport)
    }

    /// Pulls one bounded cycle. Further calls resume from the durable cursor.
    public func pull(from transport: any SyncTransport) throws {
        for _ in 0..<Self.pullPageBudget {
            let before = try client.cursor()
            try client.pull(from: transport)
            if try client.cursor() == before { return }
        }
    }

    @discardableResult
    public func push(
        to transport: any AsyncSyncTransport,
        credential: @escaping @Sendable () throws -> String
    ) async throws -> [SyncReceipt] {
        try await client.push(to: transport, credential: credential)
    }

    /// Pulls one bounded cycle. Further calls resume from the durable cursor.
    public func pull(
        from transport: any AsyncSyncTransport,
        credential: @escaping @Sendable () throws -> String
    ) async throws {
        for _ in 0..<Self.pullPageBudget {
            try Task.checkCancellation()
            let before = try client.cursor()
            try await client.pull(from: transport, credential: credential)
            if try client.cursor() == before { return }
        }
    }

    private static func project(_ db: Database, record: SharedCapture) throws {
        let previous = try MobileCapture.filter(Column("id") == record.id.uuidString).fetchOne(db)
        if record.deleted {
            try MobileCapture.filter(Column("id") == record.id.uuidString).deleteAll(db)
            return
        }
        var capture = MobileCapture(
            id: record.id, kind: record.source.kind, url: record.source.url,
            title: record.source.title ?? "Saved source", selection: record.source.selection ?? "",
            note: record.note ?? "", createdAt: record.createdAt)
        capture.localID = previous?.localID
        capture.manualTags = record.manualTags
        capture.generatedTags = record.generated.tags
        capture.body = record.generated.body
        capture.ocrText = record.generated.ocrText
        capture.noteConflicts = record.noteConflicts
        capture.seenCount = record.seenCount
        capture.revision = record.revision
        capture.metadata = record.metadata
        capture.createdAtReferenceSeconds = record.createdAt.timeIntervalSinceReferenceDate
        if previous != nil { try capture.update(db) } else { try capture.insert(db) }
    }
}
