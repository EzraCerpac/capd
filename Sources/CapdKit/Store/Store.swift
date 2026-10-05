import CapdSync
import Foundation
import GRDB
import SQLite3

public enum StoreError: Error, Equatable {
    /// The file on disk was written by a newer build of Capd than this one.
    case databaseIsNewerThanApp
    case databaseNeedsMigration
}

public enum RatingError: Error, Equatable, Sendable {
    case outOfRange(Int)
}

extension RatingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .outOfRange(let rating):
            "A capture rating must be from 1 through 5, not \(rating)."
        }
    }
}

extension StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseIsNewerThanApp:
            "The capture database was written by a newer version of Capd."
        case .databaseNeedsMigration:
            "The capture database needs an upgrade. Run `capd list` or open the Capd app, then retry."
        }
    }
}

enum EnrichmentError: Error, Equatable {
    case captureNotFound(Int64)
    case illegalTransition(from: EnrichmentState, to: EnrichmentState)
}

/// The database every Capd process shares.
///
/// The menu-bar app, `capd-agent`, and the `capd` CLI are three unsandboxed processes on one
/// file, so this opens in WAL mode with a busy timeout rather than assuming sole ownership.
public final class Store: Sendable {
    public let paths: StoragePaths

    let dbPool: DatabasePool
    public let syncClient: SyncClient?

    /// Reads are public; writes stay internal so every capture goes through the one service
    /// that applies the capture guards.
    public var reader: any DatabaseReader { dbPool }

    public convenience init(
        paths: StoragePaths, syncBinding: SyncLibraryBinding? = nil,
        imported: StoreSyncImportHandoff? = nil, deviceID: UUID? = nil
    ) throws {
        try self.init(
            paths: paths, syncBinding: syncBinding, imported: imported,
            deviceID: deviceID, commitConfiguration: { _ in })
    }

    init(readOnlyPaths paths: StoragePaths) throws {
        self.paths = paths
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        dbPool = try DatabasePool(path: paths.databaseURL.path, configuration: configuration)
        syncClient = nil
        if try dbPool.read(Migrations.migrator.hasBeenSuperseded) {
            throw StoreError.databaseIsNewerThanApp
        }
        if try !dbPool.read(Migrations.migrator.hasCompletedMigrations) {
            throw StoreError.databaseNeedsMigration
        }
    }

    init(
        paths: StoragePaths, syncBinding: SyncLibraryBinding?,
        imported: StoreSyncImportHandoff?, deviceID: UUID?,
        commitConfiguration: @escaping @Sendable (Database) throws -> Void
    ) throws {
        self.paths = paths
        try paths.createDirectories()
        dbPool = try Self.openCoordinated(at: paths.databaseURL)
        guard let syncBinding else {
            guard imported == nil, deviceID == nil else { throw SyncError.invalidOperation }
            syncClient = nil
            return
        }
        if let imported, let deviceID, deviceID != imported.deviceID { throw SyncError.wrongDevice }
        try dbPool.read { db in
            if try StoreSync.binding(in: db) == nil, try Capture.fetchCount(db) > 0 {
                guard let imported else { throw SyncBindingError.enrollmentRequiresEmptyLibrary }
                guard imported.binding == syncBinding else { throw SyncBindingError.mismatch }
                try imported.validate(db, paths: paths)
            } else if imported != nil {
                throw SyncError.invalidOperation
            }
        }
        let blobs = try BlobStore(
            directory: paths.assetsDirectory.appendingPathComponent("sync"), binding: syncBinding)
        let originalBlobFiles = Set(
            try FileManager.default.contentsOfDirectory(atPath: blobs.directory.path))
        do {
            syncClient = try SyncClient(
                writer: dbPool, blobs: blobs,
                deviceID: deviceID ?? imported?.deviceID, binding: syncBinding,
                prepareProjection: { db in
                    try StoreSync.prepareIDs(db)
                    if let imported {
                        try imported.validate(db, paths: paths)
                        try imported.seed(db, paths: paths, blobs: blobs)
                    }
                    try commitConfiguration(db)
                },
                project: { db, record in try StoreSync.project(db, record: record, paths: paths) })
        } catch {
            if imported != nil, try dbPool.read({ try StoreSync.binding(in: $0) }) == nil {
                let added = Set(
                    try FileManager.default.contentsOfDirectory(atPath: blobs.directory.path)
                ).subtracting(originalBlobFiles)
                for name in added {
                    try FileManager.default.removeItem(
                        at: blobs.directory.appendingPathComponent(name))
                }
            }
            throw error
        }
    }

    /// The hash check shares the write transaction rather than relying on the unique index,
    /// so the choice between inserting and merging is atomic across the three processes.
    func upsertCapture(_ capture: Capture) throws -> CaptureOutcome {
        try write { db in
            if let hash = capture.contentHash,
                var existing = try Capture.filter(Capture.CodingKeys.contentHash == hash)
                    .fetchOne(db)
            {
                let before = existing
                let previousSeenAt = existing.lastSeenAt
                existing.seenCount += 1
                existing.lastSeenAt = capture.createdAt
                existing.updatedAt = capture.createdAt
                existing.title = existing.title ?? capture.title
                existing.note = existing.note ?? capture.note
                existing.selection = existing.selection ?? capture.selection
                if existing.tags == nil, let tags = capture.tags {
                    existing.tags = tags
                    existing.tagsVersion = capture.tagsVersion
                }

                // An incoming `.pending` means this request wants enrichment; a broken row is
                // repaired by re-queueing it, but a healthy one is left alone.
                if capture.enrichmentState == .pending,
                    existing.enrichmentState == .failed || existing.enrichmentState == .thin
                {
                    existing.enrichmentState = .pending
                    existing.attemptCount = 0
                    existing.lastAttemptAt = nil
                }

                try existing.update(db)
                try enqueueChanges(from: before, to: existing, in: db, recapture: true)
                return .alreadyCaptured(existing, previousSeenAt: previousSeenAt)
            }

            var inserted = capture
            try inserted.insert(db)
            try enqueueCreated(inserted, in: db)
            return .captured(inserted)
        }
    }

    func updateNote(id: Int64, note: String?, now: Date = Date()) throws -> Capture {
        try write { db in
            guard let current = try Capture.fetchOne(db, key: id) else {
                throw CaptureError.notFound(id)
            }
            var updated = current
            updated.note = note
            updated.updatedAt = now
            try updated.updateChanges(db, from: current)
            try enqueueChanges(from: current, to: updated, in: db)
            return updated
        }
    }

    /// Changes the user's preference for a capture and returns the persisted row.
    public func updateRating(id: Int64, rating: Int, now: Date = Date()) throws -> Capture {
        guard Capture.ratingRange.contains(rating) else {
            throw RatingError.outOfRange(rating)
        }
        return try write { db in
            guard let current = try Capture.fetchOne(db, key: id) else {
                throw CaptureError.notFound(id)
            }
            var updated = current
            updated.rating = rating
            updated.updatedAt = now
            try updated.updateChanges(db, from: current)
            try enqueueChanges(from: current, to: updated, in: db)
            return updated
        }
    }

    public func scheduleReminder(id: Int64, at date: Date, now: Date = Date()) throws -> Capture {
        try write { db in
            guard let current = try Capture.fetchOne(db, key: id) else {
                throw CaptureError.notFound(id)
            }
            var updated = current
            updated.reminderAt = date
            updated.updatedAt = now
            try updated.updateChanges(db, from: current)
            try enqueueChanges(from: current, to: updated, in: db)
            return updated
        }
    }

    public func claimNextDueReminder(now: Date = Date()) throws -> Capture? {
        try write { db in
            guard
                let due =
                    try Capture
                    .filter(Capture.CodingKeys.reminderAt != nil)
                    .filter(Capture.CodingKeys.reminderAt <= now)
                    .order(Capture.CodingKeys.reminderAt.asc)
                    .fetchOne(db), let id = due.id
            else { return nil }
            try Capture.filter(Capture.CodingKeys.id == id).updateAll(
                db,
                Capture.CodingKeys.reminderAt.set(to: nil),
                Capture.CodingKeys.updatedAt.set(to: now))
            if var updated = try Capture.fetchOne(db, key: id) {
                updated.updatedAt = now
                try enqueueChanges(from: due, to: updated, in: db)
            }
            return due
        }
    }

    public func nextReminderDate() throws -> Date? {
        try dbPool.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT MIN(\(Capture.CodingKeys.reminderAt.rawValue)) FROM \(Schema.captures)"
            )
        }
    }

    /// Emits the number of captures whose enrichment failed, first immediately and then on
    /// every change, so the menu bar can badge without polling.
    public func failedEnrichmentCounts() -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try Capture
                    .filter(Capture.CodingKeys.enrichmentState == EnrichmentState.failed)
                    .fetchCount(db)
            }
            .values(in: dbPool)
    }

    /// Removes captures and their content-addressed assets, returning what was deleted.
    ///
    /// Asset removal is best-effort: the rows are already gone, and a missing file must not
    /// resurrect them as an error.
    public func deleteCaptures(ids: [Int64]) throws -> [Capture] {
        let deleted = try write { db in
            let doomed = try Capture.filter(ids.contains(Capture.CodingKeys.id)).fetchAll(db)
            try enqueueDeleted(doomed, in: db)
            try Capture.filter(ids.contains(Capture.CodingKeys.id)).deleteAll(db)
            return doomed
        }
        for capture in deleted {
            guard let assetPath = capture.assetPath else { continue }
            if syncClient != nil, assetPath.hasPrefix("sync/") { continue }
            try? FileManager.default.removeItem(at: paths.assetURL(forRelativePath: assetPath))
        }
        Log.store.info("deleted \(deleted.count) capture(s)")
        return deleted
    }

    /// Puts the given captures back in the enrichment queue, returning how many moved.
    ///
    /// Any terminal row moves — requeueing an `ok` capture is a deliberate refresh. A
    /// `pending` row is already queued, and a `fetching` row belongs to whichever agent is
    /// mid-flight on it, so neither is touched.
    public func requeueCaptures(ids: [Int64]) throws -> Int {
        try requeue(
            Capture.filter(ids.contains(Capture.CodingKeys.id)),
            from: [.ok, .thin, .failed])
    }

    /// Requeues every capture whose enrichment ended badly.
    public func requeueFailedCaptures() throws -> Int {
        try requeue(Capture.all(), from: [.thin, .failed])
    }

    private func requeue(
        _ scope: QueryInterfaceRequest<Capture>,
        from states: [EnrichmentState]
    ) throws -> Int {
        let count = try write { db in
            try scope
                .filter(states.map(\.rawValue).contains(Capture.CodingKeys.enrichmentState))
                .updateAll(
                    db,
                    Capture.CodingKeys.enrichmentState.set(to: EnrichmentState.pending),
                    // Reset, or a capture that already burned its retries would requeue
                    // straight back to failed.
                    Capture.CodingKeys.attemptCount.set(to: 0),
                    Capture.CodingKeys.updatedAt.set(to: Date()))
        }
        Log.store.info("requeued \(count) capture(s) for enrichment")
        return count
    }

    /// Opens under an `NSFileCoordinator` so that two processes racing to create the database
    /// on first launch don't both try to lay down the schema.
    private static func openCoordinated(at url: URL) throws -> DatabasePool {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var result: Result<DatabasePool, any Error>?

        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinatorError) {
            url in
            result = Result { try open(at: url) }
        }

        if let coordinatorError, result == nil {
            throw coordinatorError
        }
        guard let result else {
            throw CocoaError(.fileReadUnknown)
        }
        return try result.get()
    }

    private static func open(at url: URL) throws -> DatabasePool {
        var configuration = Configuration()

        // GRDB defaults to failing immediately on a locked database, which for three processes
        // sharing one file means the CLI errors whenever the agent happens to be draining.
        configuration.busyMode = .timeout(5)

        configuration.prepareDatabase { db in
            guard !db.configuration.readonly else { return }
            // Without this, SQLite deletes the -wal and -shm files when the last connection
            // closes, and a read-only process can no longer open the database at all.
            var flag: CInt = 1
            let code = withUnsafeMutablePointer(to: &flag) { pointer in
                sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, pointer)
            }
            guard code == SQLITE_OK else {
                throw DatabaseError(resultCode: ResultCode(rawValue: code))
            }
        }

        let dbPool = try DatabasePool(path: url.path, configuration: configuration)
        let migrator = Migrations.migrator
        try migrator.migrate(dbPool)

        if try dbPool.read(migrator.hasBeenSuperseded) {
            throw StoreError.databaseIsNewerThanApp
        }

        return dbPool
    }
}
