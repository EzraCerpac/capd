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
    private let sourceWebsiteIcons: [WebsiteIconRecord]
    private let websiteIconBaseline: WebsiteIconBaseline?
    private let websiteIconAssets: ImportWebsiteIconAssets?

    private var missingWebsiteIcons: [WebsiteIconRecord] {
        let targetIDs = Set(websiteIconBaseline?.records.map(\.id) ?? [])
        return sourceWebsiteIcons.filter { !targetIDs.contains($0.id) }
    }

    public init(store: Store, transport: any BoundSyncTransport) throws {
        guard store.syncClient == nil else { throw SyncError.invalidOperation }
        let baseline = try transport.baseline()
        let icons: WebsiteIconBaseline?
        let assets: ImportWebsiteIconAssets?
        if let remote = transport as? any WebsiteIconSyncTransport {
            do {
                try remote.checkWebsiteIconCapability()
                let candidate = try remote.websiteIconBaseline()
                try Self.validateIcons(candidate, baseline: baseline, deviceID: transport.deviceID)
                let staged = try ImportWebsiteIconAssets(candidate.records)
                for reference in staged.references {
                    try staged.receive(try remote.downloadWebsiteIcon(reference), for: reference)
                }
                guard try remote.websiteIconBaseline() == candidate else {
                    throw SyncError.invalidCursor
                }
                icons = candidate
                assets = staged
            } catch SyncHTTPError.unsupportedVersion {
                icons = nil
                assets = nil
            }
        } else {
            icons = nil
            assets = nil
        }
        try self.init(
            store: store, binding: transport.binding, deviceID: transport.deviceID,
            baseline: baseline, websiteIcons: icons, iconAssets: assets)
    }

    public init(
        store: Store, transport: any AsyncSyncTransport,
        credential: @escaping @Sendable () throws -> String
    ) async throws {
        guard store.syncClient == nil else { throw SyncError.invalidOperation }
        let baseline = try await transport.importBaseline(
            credential: credential, requiringExtractionQualityContract: true)
        let icons: WebsiteIconBaseline?
        let assets: ImportWebsiteIconAssets?
        do {
            let candidate = try await transport.importWebsiteIconBaseline(
                expectedCaptureCursor: baseline.cursor, credential: credential)
            try Self.validateIcons(candidate, baseline: baseline, deviceID: transport.deviceID)
            let staged = try ImportWebsiteIconAssets(candidate.records)
            for reference in staged.references {
                try Task.checkCancellation()
                let bytes = try await transport.importWebsiteIconData(
                    reference, credential: credential)
                try staged.receive(bytes, for: reference)
            }
            guard
                try await transport.importWebsiteIconBaseline(
                    expectedCaptureCursor: baseline.cursor, credential: credential) == candidate
            else { throw SyncError.invalidCursor }
            icons = candidate
            assets = staged
        } catch SyncHTTPError.unsupportedVersion {
            icons = nil
            assets = nil
        }
        try Task.checkCancellation()
        try self.init(
            store: store, binding: transport.binding, deviceID: transport.deviceID,
            baseline: baseline, websiteIcons: icons, iconAssets: assets)
    }

    private init(
        store: Store, binding: SyncLibraryBinding, deviceID: UUID, baseline: Baseline,
        websiteIcons: WebsiteIconBaseline?, iconAssets: ImportWebsiteIconAssets?
    ) throws {
        self.binding = binding
        self.deviceID = deviceID
        self.baseline = baseline
        websiteIconBaseline = websiteIcons
        websiteIconAssets = iconAssets
        guard baseline.cursor == 1, baseline.deviceSequences.isEmpty else {
            throw SyncError.invalidOperation
        }
        let source = try store.reader.read { db in
            guard try StoreSync.binding(in: db) == nil,
                try db.tableExists("sync_capture_ids")
            else { throw SyncError.invalidOperation }
            let captures = try Capture.order(Capture.CodingKeys.id).fetchAll(db)
            let identities = try Self.identities(db)
            return (captures, identities, try Store.websiteIconRecords(in: db))
        }
        captures = source.0
        identities = source.1
        sourceWebsiteIcons = source.2
        try store.reader.read { db in try validate(db, paths: store.paths) }
    }

    func validate(_ db: Database, paths: StoragePaths) throws {
        guard try Capture.order(Capture.CodingKeys.id).fetchAll(db) == captures,
            try Self.identities(db) == identities,
            try Store.websiteIconRecords(in: db) == sourceWebsiteIcons,
            captures.count == baseline.captures.count,
            captures.count == identities.count,
            !captures.isEmpty,
            Set(baseline.captures.map(\.id)).count == baseline.captures.count,
            Set(identities.values) == Set(baseline.captures.map(\.id))
        else { throw SyncError.invalidOperation }
        if !sourceWebsiteIcons.isEmpty {
            let root = paths.assetsDirectory.standardizedFileURL.resolvingSymlinksInPath()
            let directory = root.appendingPathComponent("website-icons", isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path),
                directory.resolvingSymlinksInPath() == directory
            else { throw SyncError.invalidBlob }
            let sourceAssets = try BlobStore(directory: directory)
            for record in sourceWebsiteIcons {
                try record.validate()
                guard let content = record.content else { throw SyncError.invalidBlob }
                try WebsiteIconService.validatePNG(sourceAssets.read(content.blob))
            }
        }
        if let websiteIconBaseline {
            let target = Dictionary(
                uniqueKeysWithValues: websiteIconBaseline.records.map { ($0.id, $0) })
            for source in sourceWebsiteIcons {
                try source.validate()
                if let existing = target[source.id], existing.origin != source.origin {
                    throw SyncError.invalidOperation
                }
            }
        }
        var assets: [String: BlobReference] = [:]
        for reference in baseline.captures.compactMap(\.source.blob)
            + (websiteIconBaseline?.records ?? []).compactMap(\.content?.blob)
            + missingWebsiteIcons.compactMap(\.content?.blob)
        {
            guard assets[reference.digest] == nil || assets[reference.digest] == reference else {
                throw SyncError.invalidBlob
            }
            assets[reference.digest] = reference
        }
        guard assets.count <= 4_096,
            assets.values.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= 1_073_741_824
        else { throw SyncHTTPError.resourceLimit }
        let records = Dictionary(uniqueKeysWithValues: baseline.captures.map { ($0.id, $0) })
        for capture in captures {
            guard let id = capture.id, let uuid = identities[id], let record = records[uuid],
                !record.deleted, record.revision == 1, record.noteConflicts.isEmpty
            else { throw SyncError.invalidOperation }
            try record.validateHistorical()
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
        if !missingWebsiteIcons.isEmpty {
            let source = try BlobStore(
                directory: paths.assetsDirectory.standardizedFileURL
                    .resolvingSymlinksInPath().appendingPathComponent("website-icons"))
            for icon in missingWebsiteIcons {
                guard let content = icon.content else { throw SyncError.invalidBlob }
                let bytes = try source.read(content.blob)
                try WebsiteIconService.validatePNG(bytes)
                try blobs.receive(content.blob, offset: 0, chunk: bytes, final: true)
            }
        }
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
        if let websiteIconBaseline, let websiteIconAssets {
            try websiteIconAssets.copy(into: blobs)
            try SyncClient.seedWebsiteIconBaseline(
                in: db, baseline: websiteIconBaseline, binding: binding,
                deviceID: deviceID, blobs: blobs, deferredRecords: missingWebsiteIcons)
            for record in websiteIconBaseline.records {
                try Store.projectWebsiteIcon(in: db, record: record)
            }
        } else if !sourceWebsiteIcons.isEmpty {
            _ = try SyncClient.seedDeferredWebsiteIcons(
                in: db, records: sourceWebsiteIcons, binding: binding,
                deviceID: deviceID, blobs: blobs)
        }
    }

    private static func validateIcons(
        _ icons: WebsiteIconBaseline, baseline: Baseline, deviceID: UUID
    ) throws {
        guard icons.captureCursor == baseline.cursor, icons.cursor >= 0,
            icons.totalIconCount == icons.records.count,
            Set(icons.records.map(\.id)).count == icons.records.count,
            (icons.deviceSequences[deviceID] ?? 0) == 0
        else { throw SyncError.invalidOperation }
        for record in icons.records { try record.validate() }
        var assets: [String: BlobReference] = [:]
        for reference in baseline.captures.compactMap(\.source.blob)
            + icons.records.compactMap(\.content?.blob)
        {
            guard assets[reference.digest] == nil || assets[reference.digest] == reference else {
                throw SyncError.invalidBlob
            }
            assets[reference.digest] = reference
        }
        guard assets.count <= 4_096,
            assets.values.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= 1_073_741_824
        else { throw SyncHTTPError.resourceLimit }
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

private final class ImportWebsiteIconAssets: Sendable {
    private let blobs: BlobStore
    let references: [BlobReference]

    init(_ records: [WebsiteIconRecord]) throws {
        var unique: [String: BlobReference] = [:]
        for record in records {
            guard let content = record.content else { continue }
            try content.validate()
            guard unique[content.blob.digest] == nil || unique[content.blob.digest] == content.blob
            else { throw SyncError.invalidBlob }
            unique[content.blob.digest] = content.blob
        }
        references = unique.values.sorted { $0.digest < $1.digest }
        guard references.count <= 4_096,
            references.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= 1_073_741_824
        else { throw SyncHTTPError.resourceLimit }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("capd-import-icons-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            blobs = try BlobStore(directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: blobs.directory) }

    func receive(_ bytes: Data, for reference: BlobReference) throws {
        guard BlobReference(data: bytes) == reference else { throw SyncError.invalidBlob }
        try WebsiteIconService.validatePNG(bytes)
        try blobs.receive(reference, offset: 0, chunk: bytes, final: true)
    }

    func copy(into destination: BlobStore) throws {
        for reference in references {
            let bytes = try blobs.read(reference)
            try WebsiteIconService.validatePNG(bytes)
            try destination.receive(reference, offset: 0, chunk: bytes, final: true)
        }
    }
}
