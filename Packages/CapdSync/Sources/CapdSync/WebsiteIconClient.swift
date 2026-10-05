import Foundation
import GRDB

extension SyncClient {
    public func websiteIconRevision() throws -> Int64 {
        try read { db in
            guard try WebsiteIconDatabase.exists(db) else { return 0 }
            return try Int64.fetchOne(
                db, sql: "SELECT presentation_revision FROM sync_website_icon_meta")!
        }
    }

    public func websiteIconCursor() throws -> Int64 {
        try read { db in
            guard try WebsiteIconDatabase.exists(db) else { return 0 }
            return try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_website_icon_meta")!
        }
    }

    public func websiteIcon(in db: Database, originID: String) throws -> WebsiteIconRecord? {
        try SyncDatabase.checkBinding(db, binding)
        return try WebsiteIconDatabase.record(db, id: originID, visible: true)
    }

    public func websiteIcon(originID: String) throws -> WebsiteIconRecord? {
        try read { try websiteIcon(in: $0, originID: originID) }
    }

    public static func exportWebsiteIcons(in db: Database, includeDeleted: Bool = false) throws
        -> [WebsiteIconRecord]
    {
        try WebsiteIconDatabase.records(db, visible: true).filter { includeDeleted || !$0.deleted }
    }

    public func websiteIcons(includeDeleted: Bool = false) throws -> [WebsiteIconRecord] {
        try read { try Self.exportWebsiteIcons(in: $0, includeDeleted: includeDeleted) }
    }

    public func pendingWebsiteIconOperations() throws -> [WebsiteIconOperation] {
        try read(WebsiteIconDatabase.operations)
    }

    @discardableResult
    public func enqueueWebsiteIcon(
        origin: WebsiteIconOrigin, mutation: WebsiteIconMutation, baseRevision: Int64? = nil
    ) throws -> WebsiteIconOperation {
        try write {
            try enqueueWebsiteIcon(
                in: $0, origin: origin, mutation: mutation, baseRevision: baseRevision)
        }
    }

    /// Enlists in this client's writer transaction; propagate errors to roll back the caller's work.
    @discardableResult
    public func enqueueWebsiteIcon(
        in db: Database, origin: WebsiteIconOrigin, mutation: WebsiteIconMutation,
        baseRevision: Int64? = nil
    ) throws -> WebsiteIconOperation {
        guard ObjectIdentifier(db) == writerIdentity else { throw SyncTransactionError.wrongWriter }
        guard db.isInsideTransaction else { throw SyncTransactionError.requiresTransaction }
        try projectionGate.check()
        try SyncDatabase.checkBinding(db, binding)
        guard binding != nil else { throw SyncBindingError.bindingRequired }
        if case .upsert(let content) = mutation {
            try content.validate()
            try WebsiteIconPNG.validate(blobs.read(content.blob))
        }
        try WebsiteIconDatabase.prepare(db)
        guard try !WebsiteIconDatabase.operations(db).contains(where: { $0.origin == origin })
        else { throw WebsiteIconError.pendingOperation }
        let accepted = try WebsiteIconDatabase.record(db, id: origin.id)?.revision ?? 0
        let base = baseRevision ?? accepted
        guard base >= 0, base <= accepted else { throw SyncError.invalidOperation }
        let previous = try Int64.fetchOne(db, sql: "SELECT sequence FROM sync_website_icon_meta")!
        guard previous < Int64.max else { throw SyncError.invalidOperation }
        let operation = WebsiteIconOperation(
            deviceID: deviceID, sequence: previous + 1, origin: origin, baseRevision: base,
            mutation: mutation)
        try operation.validate()
        guard try SyncDatabase.encode(operation).count < SyncHTTPHandler.maximumBodyBytes / 2 else {
            throw SyncHTTPError.resourceLimit
        }
        try db.execute(
            sql: "INSERT INTO sync_website_icon_outbox(sequence,id,origin,payload) VALUES(?,?,?,?)",
            arguments: [
                operation.sequence, operation.id.uuidString, origin.id,
                try SyncDatabase.encode(operation),
            ])
        try db.execute(
            sql: "UPDATE sync_website_icon_meta SET sequence=?", arguments: [operation.sequence])
        try WebsiteIconDatabase.rebuild(db)
        return operation
    }

    public static func seedWebsiteIconBaseline(
        in db: Database, baseline: WebsiteIconBaseline, binding: SyncLibraryBinding, deviceID: UUID,
        blobs: BlobStore
    ) throws {
        guard db.isInsideTransaction else { throw SyncTransactionError.requiresTransaction }
        try SyncDatabase.checkBinding(db, binding)
        guard
            baseline.captureCursor
                == (try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta")!),
            blobs.binding == binding,
            try String.fetchOne(db, sql: "SELECT role FROM sync_meta") == "client",
            try String.fetchOne(db, sql: "SELECT device FROM sync_meta") == deviceID.uuidString
        else { throw SyncError.wrongDevice }
        try validateCompleteWebsiteIconBaseline(baseline)
        for record in baseline.records {
            if let content = record.content {
                try WebsiteIconPNG.validate(blobs.read(content.blob))
            }
        }
        try WebsiteIconDatabase.prepare(db)
        for table in ["records", "visible", "receipts", "devices", "feed", "outbox", "observed"] {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_website_icon_\(table)") == 0
            else { throw SyncError.invalidOperation }
        }
        guard
            try Int.fetchOne(
                db,
                sql:
                    "SELECT COUNT(*) FROM sync_website_icon_meta WHERE sequence<>0 OR cursor<>0 OR floor<>0 OR observed_sequence<>0 OR presentation_revision<>0"
            ) == 0
        else { throw SyncError.invalidOperation }
        for record in baseline.records { try WebsiteIconDatabase.save(db, record) }
        try db.execute(
            sql: "UPDATE sync_website_icon_meta SET cursor=?,sequence=?,observed_sequence=?",
            arguments: [
                baseline.cursor, baseline.deviceSequences[deviceID] ?? 0,
                baseline.deviceSequences[deviceID] ?? 0,
            ])
        try WebsiteIconDatabase.rebuild(db)
    }

    static func validateCompleteWebsiteIconBaseline(_ baseline: WebsiteIconBaseline) throws {
        guard baseline.cursor >= 0, baseline.captureCursor >= 0,
            baseline.totalIconCount == baseline.records.count, baseline.records.count <= 4096,
            baseline.deviceSequences.count <= 4096,
            baseline.deviceSequences.values.allSatisfy({ $0 >= 0 }),
            Set(baseline.records.map(\.id)).count == baseline.records.count
        else { throw SyncError.invalidCursor }
        for record in baseline.records {
            try record.validate()
            guard record.revision > 0, record.revision <= baseline.cursor else {
                throw SyncError.invalidCursor
            }
        }
        guard try SyncDatabase.encode(baseline).count <= SyncHTTPHandler.maximumBodyBytes else {
            throw SyncHTTPError.resourceLimit
        }
    }

    func validateWebsiteIconReceipt(_ receipt: WebsiteIconReceipt, operation: WebsiteIconOperation)
        throws
    {
        guard receipt.operationID == operation.id else { throw SyncHTTPError.invalidResponse }
        if let record = receipt.record {
            try record.validate()
            guard record.origin == operation.origin, record.revision > 0 else {
                throw SyncHTTPError.invalidResponse
            }
        }
        switch receipt.outcome {
        case .accepted:
            guard let record = receipt.record, record.revision > operation.baseRevision else {
                throw SyncHTTPError.invalidResponse
            }
            switch operation.mutation {
            case .upsert(let content):
                guard !record.deleted, record.content == content else {
                    throw SyncHTTPError.invalidResponse
                }
            case .tombstone: guard record.deleted else { throw SyncHTTPError.invalidResponse }
            }
        case .stale:
            guard let record = receipt.record, record.revision != operation.baseRevision else {
                throw SyncHTTPError.invalidResponse
            }
        case .unreferenced:
            guard case .upsert = operation.mutation,
                (receipt.record?.revision ?? 0) == operation.baseRevision
            else { throw SyncHTTPError.invalidResponse }
        }
    }

    func acknowledgeWebsiteIcon(_ receipt: WebsiteIconReceipt, operation: WebsiteIconOperation)
        throws
    {
        try validateWebsiteIconReceipt(receipt, operation: operation)
        try write { db in
            guard try WebsiteIconDatabase.operations(db).contains(operation) else {
                throw SyncError.invalidOperation
            }
            try validateWebsiteIconReceipt(receipt, operation: operation)
            if let record = receipt.record {
                if let current = try WebsiteIconDatabase.record(db, id: record.id) {
                    guard current.revision != record.revision || current == record else {
                        throw SyncHTTPError.invalidResponse
                    }
                    if current.revision < record.revision {
                        try WebsiteIconDatabase.save(db, record)
                    }
                } else {
                    try WebsiteIconDatabase.save(db, record)
                }
            }
            try db.execute(
                sql:
                    "DELETE FROM sync_website_icon_outbox WHERE id=?; DELETE FROM sync_website_icon_observed WHERE id=?",
                arguments: [operation.id.uuidString, operation.id.uuidString])
            try db.execute(
                sql: "UPDATE sync_website_icon_meta SET observed_sequence=MAX(observed_sequence,?)",
                arguments: [operation.sequence])
            try WebsiteIconDatabase.rebuild(db)
        }
    }

    func cacheWebsiteIcon(_ record: WebsiteIconRecord?, fetch: (BlobReference) throws -> Data)
        throws
    {
        guard let content = record?.content else { return }
        if let bytes = try? blobs.read(content.blob) {
            try WebsiteIconPNG.validate(bytes)
            return
        }
        let bytes = try fetch(content.blob)
        guard BlobReference(data: bytes) == content.blob else { throw SyncError.invalidBlob }
        try WebsiteIconPNG.validate(bytes)
        _ = try blobs.put(bytes)
    }

    func checkWebsiteIconTransport(_ transport: any BoundSyncTransport) throws {
        guard let binding else { throw SyncBindingError.bindingRequired }
        guard transport.binding == binding, transport.deviceID == deviceID else {
            throw SyncBindingError.mismatch
        }
    }

    public func pushWebsiteIcons(to transport: any WebsiteIconSyncTransport) throws {
        try checkWebsiteIconTransport(transport)
        try transport.checkWebsiteIconCapability()
        for operation in try pendingWebsiteIconOperations() {
            if case .upsert(let content) = operation.mutation {
                let bytes = try blobs.read(content.blob)
                try WebsiteIconPNG.validate(bytes)
                for offset in stride(
                    from: 0, to: bytes.count, by: SyncHTTPHandler.maximumChunkBytes)
                {
                    let end = min(bytes.count, offset + SyncHTTPHandler.maximumChunkBytes)
                    try transport.uploadWebsiteIcon(
                        content.blob, offset: offset, chunk: bytes.subdata(in: offset..<end),
                        final: end == bytes.count)
                }
            }
            let receipt = try transport.applyWebsiteIcon(operation)
            try validateWebsiteIconReceipt(receipt, operation: operation)
            try cacheWebsiteIcon(receipt.record, fetch: transport.downloadWebsiteIcon)
            try acknowledgeWebsiteIcon(receipt, operation: operation)
        }
    }

    func validateWebsiteIconPage(_ page: WebsiteIconFeedPage, cursor: Int64) throws {
        guard page.changes.count <= SyncHTTPHandler.maximumPageSize else {
            throw SyncError.invalidCursor
        }
        var expected = cursor
        for change in page.changes {
            guard expected < Int64.max else { throw SyncError.invalidCursor }
            expected += 1
            try change.record.validate()
            guard change.cursor == expected, change.record.revision == expected else {
                throw SyncError.invalidCursor
            }
            let identityCount = [
                change.operationID != nil, change.deviceID != nil, change.sequence != nil,
            ].filter { $0 }.count
            guard identityCount == 0 || identityCount == 3,
                change.sequence == nil || change.sequence! > 0
            else { throw SyncError.invalidCursor }
        }
        guard page.cursor == expected else { throw SyncError.invalidCursor }
        try read { db in
            for change in page.changes {
                if let current = try WebsiteIconDatabase.record(db, id: change.record.id),
                    current.revision == change.record.revision, current != change.record
                {
                    throw SyncError.invalidCursor
                }
                if change.deviceID == deviceID,
                    let operation = try WebsiteIconDatabase.operations(db).first(where: {
                        $0.id == change.operationID
                    })
                {
                    guard operation.sequence == change.sequence else {
                        throw SyncError.invalidCursor
                    }
                    try validateWebsiteIconReceipt(
                        WebsiteIconReceipt(
                            operationID: operation.id, outcome: .accepted, record: change.record),
                        operation: operation)
                }
            }
        }
    }

    func commitWebsiteIconPage(_ page: WebsiteIconFeedPage, cursor: Int64) throws {
        try write { db in
            try WebsiteIconDatabase.prepare(db)
            guard try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_website_icon_meta") == cursor
            else { throw SyncError.invalidCursor }
            var expected = cursor
            for change in page.changes {
                expected += 1
                guard change.cursor == expected else { throw SyncError.invalidCursor }
                let current = try WebsiteIconDatabase.record(db, id: change.record.id)
                guard current?.revision != change.record.revision || current == change.record else {
                    throw SyncError.invalidCursor
                }
                if (current?.revision ?? 0) < change.record.revision {
                    try WebsiteIconDatabase.save(db, change.record)
                }
                if change.deviceID == deviceID, let id = change.operationID,
                    let sequence = change.sequence
                {
                    if let operation = try WebsiteIconDatabase.operations(db).first(where: {
                        $0.id == id
                    }) {
                        guard operation.sequence == sequence else { throw SyncError.invalidCursor }
                        try validateWebsiteIconReceipt(
                            WebsiteIconReceipt(
                                operationID: id, outcome: .accepted, record: change.record),
                            operation: operation)
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO sync_website_icon_observed(id) VALUES(?)",
                            arguments: [id.uuidString])
                    }
                    try db.execute(
                        sql:
                            "UPDATE sync_website_icon_meta SET sequence=MAX(sequence,?),observed_sequence=MAX(observed_sequence,?)",
                        arguments: [sequence, sequence])
                }
            }
            try db.execute(
                sql: "UPDATE sync_website_icon_meta SET cursor=?", arguments: [page.cursor])
            try WebsiteIconDatabase.rebuild(db)
        }
    }

    func validateWebsiteIconBaseline(_ baseline: WebsiteIconBaseline, in db: Database) throws {
        try Self.validateCompleteWebsiteIconBaseline(baseline)
        let incoming = Dictionary(uniqueKeysWithValues: baseline.records.map { ($0.id, $0) })
        for local in try WebsiteIconDatabase.records(db) {
            if local.revision <= baseline.cursor {
                guard let record = incoming[local.id], record.revision >= local.revision,
                    record.revision != local.revision || record == local
                else { throw SyncError.invalidCursor }
            }
        }
        let serverSequence = baseline.deviceSequences[deviceID] ?? 0
        for operation in try WebsiteIconDatabase.operations(db)
        where operation.sequence <= serverSequence {
            guard
                try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM sync_website_icon_observed WHERE id=?)",
                    arguments: [operation.id.uuidString]) == true
            else { throw SyncError.recoverySequenceCollision }
        }
    }

    func commitWebsiteIconBaseline(_ baseline: WebsiteIconBaseline) throws {
        try write { db in
            try validateWebsiteIconBaseline(baseline, in: db)
            try WebsiteIconDatabase.prepare(db)
            guard
                baseline.cursor
                    >= (try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_website_icon_meta")!)
            else { throw SyncError.invalidCursor }
            for record in baseline.records
            where (try WebsiteIconDatabase.record(db, id: record.id)?.revision ?? 0)
                <= record.revision
            { try WebsiteIconDatabase.save(db, record) }
            try db.execute(
                sql: "UPDATE sync_website_icon_meta SET cursor=?,sequence=MAX(sequence,?)",
                arguments: [baseline.cursor, baseline.deviceSequences[deviceID] ?? 0])
            try WebsiteIconDatabase.rebuild(db)
        }
    }

    public func pullWebsiteIcons(from transport: any WebsiteIconSyncTransport, pageSize: Int = 100)
        throws
    {
        try checkWebsiteIconTransport(transport)
        try transport.checkWebsiteIconCapability()
        do {
            while true {
                let cursor = try websiteIconCursor()
                let page = try transport.websiteIconChanges(after: cursor, limit: pageSize)
                try validateWebsiteIconPage(page, cursor: cursor)
                for change in page.changes {
                    try cacheWebsiteIcon(change.record, fetch: transport.downloadWebsiteIcon)
                }
                try commitWebsiteIconPage(page, cursor: cursor)
                if page.changes.isEmpty { return }
            }
        } catch SyncError.cursorExpired {
            let baseline = try transport.websiteIconBaseline()
            try read { try validateWebsiteIconBaseline(baseline, in: $0) }
            for record in baseline.records {
                try cacheWebsiteIcon(record, fetch: transport.downloadWebsiteIcon)
            }
            try commitWebsiteIconBaseline(baseline)
        }
    }
}
