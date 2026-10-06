import Foundation
import GRDB

extension SyncServer {
    public func uploadWebsiteIcon(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool)
        throws
    {
        try read { _ in }
        guard (1...262_144).contains(blob.byteCount),
            chunk.count <= SyncHTTPHandler.maximumChunkBytes
        else { throw SyncHTTPError.resourceLimit }
        try blobs.receive(
            blob, offset: offset, chunk: chunk, final: final, validating: WebsiteIconPNG.validate)
    }

    public func applyWebsiteIcon(_ operation: WebsiteIconOperation) throws -> WebsiteIconReceipt {
        try applyWebsiteIcon(operation, validating: { _ in })
    }

    func applyWebsiteIcon(
        _ operation: WebsiteIconOperation, validating: (WebsiteIconReceipt) throws -> Void
    ) throws -> WebsiteIconReceipt {
        try write { db in
            try WebsiteIconDatabase.prepare(db)
            if try Bool.fetchOne(
                db,
                sql:
                    "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_service_writers')"
            )!,
                try String.fetchOne(
                    db, sql: "SELECT principal FROM sync_service_writers WHERE device=?",
                    arguments: [operation.deviceID.uuidString]) != nil
            {
                throw SyncError.wrongDevice
            }
            if let row = try Row.fetchOne(
                db, sql: "SELECT operation,receipt FROM sync_website_icon_receipts WHERE id=?",
                arguments: [operation.id.uuidString])
            {
                guard
                    try SyncDatabase.decode(WebsiteIconOperation.self, row["operation"])
                        == operation
                else { throw SyncError.operationIDReused }
                let receipt = try SyncDatabase.decode(WebsiteIconReceipt.self, row["receipt"])
                try validating(receipt)
                return receipt
            }
            try operation.validate()
            let deviceCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM sync_website_icon_devices")!
            let knownDevice = try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM sync_website_icon_devices WHERE id=?)",
                arguments: [operation.deviceID.uuidString])!
            guard deviceCount < 4096 || knownDevice else { throw SyncHTTPError.resourceLimit }
            let previous =
                try Int64.fetchOne(
                    db, sql: "SELECT sequence FROM sync_website_icon_devices WHERE id=?",
                    arguments: [operation.deviceID.uuidString]) ?? 0
            guard previous < Int64.max, operation.sequence == previous + 1 else {
                throw SyncError.outOfOrder(
                    expected: previous == Int64.max ? previous : previous + 1)
            }
            let current = try WebsiteIconDatabase.record(db, id: operation.origin.id)
            let outcome: WebsiteIconReceipt.Outcome
            var record = current
            if operation.baseRevision != (current?.revision ?? 0) {
                outcome = .stale
            } else if case .upsert = operation.mutation,
                try !WebsiteIconDatabase.referenced(db, operation.origin.id)
            {
                outcome = .unreferenced
            } else {
                let content: WebsiteIconContent?
                let deleted: Bool
                switch operation.mutation {
                case .upsert(let value):
                    try WebsiteIconPNG.validate(blobs.read(value.blob))
                    content = value
                    deleted = false
                case .tombstone:
                    content = current?.content
                    deleted = true
                }
                if current == nil,
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_website_icon_records")!
                        >= 4096
                {
                    outcome = .capacityRejected
                } else {
                    record = WebsiteIconRecord(
                        origin: operation.origin, revision: try WebsiteIconDatabase.nextCursor(db),
                        deleted: deleted, content: content)
                    outcome = .accepted
                }
            }
            let receipt = WebsiteIconReceipt(
                operationID: operation.id, outcome: outcome, record: record)
            try validating(receipt)
            if outcome == .accepted, let record {
                try WebsiteIconDatabase.save(db, record)
                try WebsiteIconDatabase.append(
                    db,
                    WebsiteIconFeedChange(
                        cursor: record.revision, record: record, operationID: operation.id,
                        deviceID: operation.deviceID, sequence: operation.sequence))
            }
            try db.execute(
                sql: "INSERT INTO sync_website_icon_receipts(id,operation,receipt) VALUES(?,?,?)",
                arguments: [
                    operation.id.uuidString, try SyncDatabase.encode(operation),
                    try SyncDatabase.encode(receipt),
                ])
            try db.execute(
                sql:
                    "INSERT INTO sync_website_icon_devices(id,sequence) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET sequence=excluded.sequence",
                arguments: [operation.deviceID.uuidString, operation.sequence])
            return receipt
        }
    }

    public func websiteIconChanges(after cursor: Int64, limit: Int = 100) throws
        -> WebsiteIconFeedPage
    {
        guard (1...SyncHTTPHandler.maximumPageSize).contains(limit) else {
            throw SyncError.invalidCursor
        }
        return try write { db in
            try WebsiteIconDatabase.prepare(db)
            let meta = try Row.fetchOne(db, sql: "SELECT cursor,floor FROM sync_website_icon_meta")!
            guard cursor >= (meta["floor"] as Int64) else { throw SyncError.cursorExpired }
            guard cursor >= 0, cursor <= (meta["cursor"] as Int64) else {
                throw SyncError.invalidCursor
            }
            let values = try Data.fetchAll(
                db,
                sql:
                    "SELECT payload FROM sync_website_icon_feed WHERE cursor>? ORDER BY cursor LIMIT ?",
                arguments: [cursor, limit]
            ).map { try SyncDatabase.decode(WebsiteIconFeedChange.self, $0) }
            return WebsiteIconFeedPage(cursor: values.last?.cursor ?? cursor, changes: values)
        }
    }

    public func websiteIconBaseline() throws -> WebsiteIconBaseline {
        try websiteIconBaselinePage(afterOriginID: nil, limit: nil)
    }

    public func websiteIconBaselinePage(
        afterOriginID: String?, limit: Int?, expectedCursor: Int64? = nil,
        expectedCaptureCursor: Int64? = nil
    ) throws -> WebsiteIconBaseline {
        if let limit, !(0...SyncHTTPHandler.maximumPageSize).contains(limit) {
            throw SyncError.invalidCursor
        }
        return try write { db in
            try WebsiteIconDatabase.prepare(db)
            let cursor = try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_website_icon_meta")!
            let captureCursor = try Int64.fetchOne(db, sql: "SELECT cursor FROM sync_meta")!
            guard expectedCursor == nil || expectedCursor == cursor,
                expectedCaptureCursor == nil || expectedCaptureCursor == captureCursor
            else { throw SyncError.invalidCursor }
            guard
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_website_icon_records")!
                    <= 4096,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_website_icon_devices")! <= 4096
            else { throw SyncHTTPError.resourceLimit }
            let values = try Data.fetchAll(
                db,
                sql: "SELECT payload FROM sync_website_icon_records WHERE id>? ORDER BY id LIMIT ?",
                arguments: [afterOriginID ?? "", limit ?? Int.max]
            ).map { try SyncDatabase.decode(WebsiteIconRecord.self, $0) }
            var sequences: [UUID: Int64] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT id,sequence FROM sync_website_icon_devices")
            {
                guard let device = UUID(uuidString: row["id"]) else { throw SyncError.wrongDevice }
                sequences[device] = row["sequence"]
            }
            return WebsiteIconBaseline(
                cursor: cursor, captureCursor: captureCursor, records: values,
                deviceSequences: sequences,
                totalIconCount: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM sync_website_icon_records")!)
        }
    }

    public func expireWebsiteIconFeed() throws {
        try write { db in
            try WebsiteIconDatabase.prepare(db)
            try db.execute(
                sql:
                    "DELETE FROM sync_website_icon_feed; UPDATE sync_website_icon_meta SET floor=cursor"
            )
        }
    }
}
