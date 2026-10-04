import CapdSync
import Foundation
import GRDB

/// A verified initial-import baseline for a quiesced, copied Mac library.
public struct StoreSyncImportHandoff: Sendable {
    let binding: SyncLibraryBinding
    let deviceID: UUID
    private let baseline: Baseline
    private let captures: [Capture]
    private let identities: [Int64: UUID]

    public init(store: Store, transport: any BoundSyncTransport) throws {
        guard store.syncClient == nil else { throw SyncError.invalidOperation }
        try self.init(
            store: store, binding: transport.binding, deviceID: transport.deviceID,
            baseline: transport.baseline())
    }

    public init(
        store: Store, transport: any AsyncSyncTransport,
        credential: @escaping @Sendable () throws -> String
    ) async throws {
        guard store.syncClient == nil else { throw SyncError.invalidOperation }
        let baseline = try await transport.importBaseline(credential: credential)
        try Task.checkCancellation()
        try self.init(
            store: store, binding: transport.binding, deviceID: transport.deviceID,
            baseline: baseline)
    }

    private init(
        store: Store, binding: SyncLibraryBinding, deviceID: UUID, baseline: Baseline
    ) throws {
        self.binding = binding
        self.deviceID = deviceID
        self.baseline = baseline
        guard baseline.cursor == 1, baseline.deviceSequences.isEmpty else {
            throw SyncError.invalidOperation
        }
        let source = try store.reader.read { db in
            guard try StoreSync.binding(in: db) == nil,
                try db.tableExists("sync_capture_ids")
            else { throw SyncError.invalidOperation }
            let captures = try Capture.order(Capture.CodingKeys.id).fetchAll(db)
            let identities = try Self.identities(db)
            return (captures, identities)
        }
        captures = source.0
        identities = source.1
        try store.reader.read { db in try validate(db, paths: store.paths) }
    }

    func validate(_ db: Database, paths: StoragePaths) throws {
        guard try Capture.order(Capture.CodingKeys.id).fetchAll(db) == captures,
            try Self.identities(db) == identities,
            captures.count == baseline.captures.count,
            captures.count == identities.count,
            !captures.isEmpty,
            Set(baseline.captures.map(\.id)).count == baseline.captures.count,
            Set(identities.values) == Set(baseline.captures.map(\.id))
        else { throw SyncError.invalidOperation }
        let records = Dictionary(uniqueKeysWithValues: baseline.captures.map { ($0.id, $0) })
        for capture in captures {
            guard let id = capture.id, let uuid = identities[id], let record = records[uuid],
                !record.deleted, record.revision == 1, record.noteConflicts.isEmpty
            else { throw SyncError.invalidOperation }
            let blob = try StoreSync.reference(for: capture, paths: paths)
            guard (blob?.byteCount ?? 0) <= 8_388_608 else { throw SyncError.invalidBlob }
            let local = StoreSync.snapshot(capture, id: uuid, blob: blob)
            guard local.source == record.source, local.createdAt == record.createdAt,
                local.note == record.note, local.rating == record.rating,
                local.seenCount == record.seenCount,
                local.manualTags == record.manualTags, local.generated == record.generated,
                local.metadata == record.metadata
            else { throw SyncError.invalidOperation }
        }
    }

    func seed(_ db: Database, paths: StoragePaths, blobs: BlobStore) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let records = Dictionary(uniqueKeysWithValues: baseline.captures.map { ($0.id, $0) })
        for capture in captures {
            let staged = try StoreSync.blob(for: capture, paths: paths, store: blobs)
            guard let localID = capture.id, let uuid = identities[localID],
                staged == records[uuid]?.source.blob
            else { throw SyncError.invalidBlob }
        }
        for record in baseline.captures {
            let payload = try encoder.encode(record)
            try db.execute(
                sql: "INSERT INTO sync_records (id,payload) VALUES (?,?)",
                arguments: [record.id.uuidString, payload])
            try db.execute(
                sql: "INSERT INTO sync_visible (id,payload) VALUES (?,?)",
                arguments: [record.id.uuidString, payload])
        }
        try db.execute(
            sql: "UPDATE sync_meta SET cursor=? WHERE id=1", arguments: [baseline.cursor])
    }

    private static func identities(_ db: Database) throws -> [Int64: UUID] {
        try Dictionary(
            uniqueKeysWithValues: Row.fetchAll(
                db, sql: "SELECT local_id,global_id FROM sync_capture_ids"
            ).map { row in
                let localID: Int64 = row["local_id"]
                let value: String = row["global_id"]
                guard let uuid = UUID(uuidString: value) else { throw SyncError.invalidOperation }
                return (localID, uuid)
            })
    }
}
