import CapdSync
import Foundation
import GRDB

enum StoreSync {
    static func binding(in db: Database) throws -> SyncLibraryBinding? {
        guard try db.tableExists("sync_binding"),
            let payload = try Data.fetchOne(db, sql: "SELECT payload FROM sync_binding WHERE id=1")
        else { return nil }
        return try JSONDecoder().decode(SyncLibraryBinding.self, from: payload)
    }

    static func checkBinding(_ db: Database, expected: SyncLibraryBinding?) throws {
        guard try binding(in: db) == expected else { throw SyncBindingError.mismatch }
    }

    static func prepareIDs(_ db: Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE IF NOT EXISTS sync_capture_ids (
                    local_id INTEGER PRIMARY KEY, global_id TEXT NOT NULL UNIQUE)
                """)
    }

    static func identity(_ db: Database, capture: Capture) throws -> UUID {
        guard let localID = capture.id else { throw SyncError.invalidOperation }
        if let stored = try String.fetchOne(
            db, sql: "SELECT global_id FROM sync_capture_ids WHERE local_id=?", arguments: [localID]
        ) {
            guard let uuid = UUID(uuidString: stored) else { throw SyncError.invalidOperation }
            return uuid
        }
        let uuid = UUID()
        try db.execute(
            sql: "INSERT INTO sync_capture_ids VALUES (?,?)", arguments: [localID, uuid.uuidString])
        return uuid
    }

    static func visible(_ db: Database, id: UUID) throws -> SharedCapture? {
        let canonical =
            try String.fetchOne(
                db, sql: "SELECT canonical FROM sync_aliases WHERE id=?", arguments: [id.uuidString]
            ) ?? id.uuidString
        guard
            let payload = try Data.fetchOne(
                db, sql: "SELECT payload FROM sync_visible WHERE id=?", arguments: [canonical])
        else { return nil }
        return try JSONDecoder().decode(SharedCapture.self, from: payload)
    }

    static func snapshot(_ capture: Capture, id: UUID, blob: BlobReference? = nil) -> SharedCapture
    {
        SyncPrototype.snapshot(capture, globalID: id, blob: blob)
    }

    static func blob(for capture: Capture, paths: StoragePaths, store: BlobStore) throws
        -> BlobReference?
    {
        guard let reference = try reference(for: capture, paths: paths),
            let path = capture.assetPath
        else { return nil }
        let data = try Data(contentsOf: paths.assetURL(forRelativePath: path))
        try store.receive(reference, offset: 0, chunk: data, final: true)
        return reference
    }

    static func reference(for capture: Capture, paths: StoragePaths) throws -> BlobReference? {
        guard let path = capture.assetPath else {
            guard capture.kind != .image else { throw SyncError.blobMissing }
            return nil
        }
        let root = paths.assetsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let url = paths.assetURL(forRelativePath: path).standardizedFileURL
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
            url.resolvingSymlinksInPath() == url, url.path.hasPrefix(root.path + "/")
        else { throw SyncError.invalidBlob }
        let data = try Data(contentsOf: url)
        return BlobReference(data: data)
    }

    static func project(_ db: Database, record: SharedCapture, paths: StoragePaths) throws {
        var localID = try Int64.fetchOne(
            db, sql: "SELECT local_id FROM sync_capture_ids WHERE global_id=? COLLATE NOCASE",
            arguments: [record.id.uuidString])
        if localID == nil {
            localID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT local_id FROM sync_capture_ids JOIN sync_aliases
                    ON sync_capture_ids.global_id=sync_aliases.id COLLATE NOCASE
                    WHERE sync_aliases.canonical=? ORDER BY local_id LIMIT 1
                    """, arguments: [record.id.uuidString])
            if let localID {
                try db.execute(
                    sql: "UPDATE sync_capture_ids SET global_id=? WHERE local_id=?",
                    arguments: [record.id.uuidString, localID])
            }
        }
        let original = try localID.flatMap { try Capture.fetchOne(db, key: $0) }
        if record.deleted {
            // A rejected duplicate can alias a newer local row to an older tombstone.
            // Retain every identity mapping, but remove all of their local projections.
            let tombstonedIDs = try Int64.fetchAll(
                db,
                sql: """
                    SELECT local_id FROM sync_capture_ids
                    WHERE global_id=? COLLATE NOCASE OR global_id IN (
                        SELECT id FROM sync_aliases WHERE canonical=? COLLATE NOCASE)
                    """, arguments: [record.id.uuidString, record.id.uuidString])
            try Capture.filter(tombstonedIDs.contains(Capture.CodingKeys.id)).deleteAll(db)
            return
        }
        var capture =
            original
            ?? Capture(
                id: localID, kind: CaptureKind(rawValue: record.source.kind.rawValue)!,
                createdAt: record.createdAt)
        capture.url = record.source.url
        capture.host = record.source.host
        capture.title = record.source.title
        capture.selection = record.source.selection
        capture.contentHash = record.source.contentHash
        capture.note = record.note
        capture.rating = record.rating
        capture.seenCount = record.seenCount
        capture.body = record.generated.body
        capture.ocrText = record.generated.ocrText
        if original == nil || capture.enrichmentState == .pending {
            switch capture.kind {
            case .text:
                capture.enrichmentState = .ok
            case .link where record.generated.body != nil:
                capture.enrichmentState = record.generated.body!.isEmpty ? .thin : .ok
                capture.bodyStatus = record.generated.body!.isEmpty ? .thin : .ok
            case .image where record.generated.ocrText != nil:
                capture.enrichmentState = .ok
            default: break
            }
        }
        if let metadata = record.metadata {
            if let updatedAt = metadata.updatedAt { capture.updatedAt = updatedAt }
            if let lastSeenAt = metadata.lastSeenAt { capture.lastSeenAt = lastSeenAt }
            capture.reminderAt = metadata.reminderAt
            capture.sourceAppBundleID = metadata.sourceAppBundleID
        }
        let tags = Set(record.manualTags).union(record.generated.tags)
        if Set(capture.tagList) != tags {
            capture.tags = tags.isEmpty ? nil : tags.sorted().joined(separator: " ")
        }
        if let processed = record.generated.taggingProcessed {
            let matches = record.generated.taggingInputFingerprint == TaggingFingerprint.of(capture)
            capture.tagsVersion =
                processed && matches
                ? (record.manualTags.isEmpty
                    ? max(1, capture.tagsVersion) : Capture.pinnedTagsVersion)
                : 0
        } else if !record.manualTags.isEmpty {
            capture.tagsVersion = Capture.pinnedTagsVersion
        } else if !record.generated.tags.isEmpty {
            capture.tagsVersion = max(1, capture.tagsVersion)
        } else if original == nil || capture.tagsVersion == Capture.pinnedTagsVersion {
            capture.tagsVersion = 0
        }
        if let blob = record.source.blob, capture.assetPath == nil {
            capture.assetPath = "sync/" + blob.digest
        }
        if original != nil { try capture.update(db) } else { try capture.insert(db) }
        try db.execute(
            sql:
                "INSERT INTO sync_capture_ids VALUES (?,?) ON CONFLICT(global_id) DO UPDATE SET local_id=excluded.local_id",
            arguments: [capture.id, record.id.uuidString])
    }
}

extension Store {
    func syncTags(_ capture: Capture, in db: Database) throws -> (
        manual: [String], generated: [String]
    ) {
        if syncClient != nil {
            let id = try StoreSync.identity(db, capture: capture)
            if let record = try StoreSync.visible(db, id: id) {
                return (record.manualTags, record.generated.tags)
            }
        }
        return capture.tagsVersion == Capture.pinnedTagsVersion
            ? (capture.tagList, []) : ([], capture.tagList)
    }

    func write<T>(_ body: (Database) throws -> T) throws -> T {
        try dbPool.write { db in
            try StoreSync.checkBinding(db, expected: syncClient?.binding)
            return try body(db)
        }
    }

    func enqueueCreated(_ capture: Capture, in db: Database) throws {
        guard let client = syncClient else { return }
        let id = try StoreSync.identity(db, capture: capture)
        let blob = try StoreSync.blob(for: capture, paths: paths, store: client.blobs)
        let record = StoreSync.snapshot(capture, id: id, blob: blob)
        try client.enqueue(in: db, captureID: id, mutation: .create(record))
    }

    func enqueueChanges(
        from before: Capture, to after: Capture, in db: Database, recapture: Bool = false,
        generatedTags: [String]? = nil, taggingProcessing: TaggingProcessingUpdate? = nil
    ) throws {
        guard let client = syncClient else { return }
        let id = try StoreSync.identity(db, capture: before)
        let current = try StoreSync.visible(db, id: id)
        guard current != nil else { throw SyncError.invalidOperation }
        var edit = CaptureEdit()
        if before.note != after.note { edit.note = NoteEdit(after.note) }
        if before.rating != after.rating { edit.rating = after.rating }
        if before.title != after.title || before.selection != after.selection {
            edit.sourceContent = SourceContentPatch(title: after.title, selection: after.selection)
        }
        var generated = GeneratedContentPatch()
        var changedGenerated = false
        if before.body != after.body {
            generated.body = after.body.map(TextUpdate.set) ?? .clear
            changedGenerated = true
        }
        if before.ocrText != after.ocrText {
            generated.ocrText = after.ocrText.map(TextUpdate.set) ?? .clear
            changedGenerated = true
        }
        if let generatedTags {
            if generatedTags != current!.generated.tags {
                generated.tags = generatedTags
                changedGenerated = true
            }
        } else if before.tags != after.tags || before.tagsVersion != after.tagsVersion {
            if after.tagsVersion == Capture.pinnedTagsVersion {
                let previous = Set(current!.manualTags)
                let next = Set(after.tagList).subtracting(current!.generated.tags)
                edit.addTags = next.subtracting(previous).sorted()
                edit.removeTags = previous.subtracting(next).sorted()
            } else {
                generated.tags = after.tagList
                changedGenerated = true
            }
        }
        if let taggingProcessing {
            generated.taggingProcessing = taggingProcessing
            changedGenerated = true
        }
        if changedGenerated { edit.generatedPatch = generated }
        let changedTime = before.updatedAt != after.updatedAt
        let changedSeen = before.lastSeenAt != after.lastSeenAt
        let changedReminder = before.reminderAt != after.reminderAt
        if changedTime || changedSeen || changedReminder {
            edit.metadata = CaptureMetadataPatch(
                updatedAt: changedTime ? after.updatedAt : nil,
                lastSeenAt: changedSeen ? after.lastSeenAt : nil,
                reminder: changedReminder
                    ? (after.reminderAt.map(ReminderUpdate.set) ?? .clear) : nil)
        }
        if recapture { try client.enqueue(in: db, captureID: id, mutation: .recapture) }
        if edit != CaptureEdit() {
            try client.enqueue(in: db, captureID: id, mutation: .edit(edit))
        }
    }

    func enqueueDeleted(_ capture: Capture, in db: Database) throws {
        guard let client = syncClient else { return }
        let id = try StoreSync.identity(db, capture: capture)
        try client.enqueue(in: db, captureID: id, mutation: .delete)
    }
}
