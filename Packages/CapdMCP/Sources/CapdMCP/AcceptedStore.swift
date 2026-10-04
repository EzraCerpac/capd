import CapdSync
import Foundation
import GRDB

public enum MCPFailure: Error { case invalidArguments, unavailable, capacity, forbidden }

/// Opens an EXISTING authority database read-only. No migrations, blobs or local projections.
/// This deliberately fails closed above the bounded-library budget until an indexed reader is agreed.
public final class AcceptedStore: Sendable {
    private let reader: DatabaseQueue
    public let binding: SyncLibraryBinding
    public init(databaseURL: URL, binding: SyncLibraryBinding) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(1)
        reader = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        self.binding = binding
        try reader.read { db in
            // MCP must never repair or initialize an authority through a writer open.
            let tables = [
                "sync_meta", "sync_records", "sync_aliases", "sync_receipts",
                "sync_devices", "sync_feed", "sync_outbox", "sync_visible",
                "sync_rejections", "sync_observed", "sync_binding",
            ]
            let placeholders = tables.map { _ in "?" }.joined(separator: ",")
            let present = try String.fetchAll(
                db,
                sql:
                    "SELECT name FROM sqlite_master WHERE type='table' AND name IN (\(placeholders))",
                arguments: StatementArguments(tables))
            guard Set(present) == Set(tables) else { throw MCPFailure.forbidden }
            try check(db)
        }
    }

    private func check(_ db: Database) throws {
        guard try String.fetchOne(db, sql: "SELECT role FROM sync_meta WHERE id=1") == "server",
            try String.fetchOne(db, sql: "SELECT device FROM sync_meta WHERE id=1") == nil,
            let data = try Data.fetchOne(db, sql: "SELECT payload FROM sync_binding WHERE id=1"),
            try JSONDecoder().decode(SyncLibraryBinding.self, from: data) == binding
        else { throw MCPFailure.forbidden }
    }

    public func snapshot() throws -> [SharedCapture] {
        try reader.read { db in
            try check(db)
            let cursor = try Row.fetchCursor(
                db,
                sql:
                    "SELECT CASE WHEN length(payload)<=262144 THEN payload END AS payload FROM sync_records ORDER BY id LIMIT 1001"
            )
            var captures: [SharedCapture] = []
            var bytes = 0
            var rows = 0
            while let row = try cursor.next() {
                guard let data: Data = row["payload"] else { throw MCPFailure.capacity }
                rows += 1
                bytes += data.count
                guard rows <= 1000, data.count <= 262_144, bytes <= 8_388_608 else {
                    throw MCPFailure.capacity
                }
                let capture = try JSONDecoder().decode(SharedCapture.self, from: data)
                if !capture.deleted { captures.append(capture) }
            }
            return captures
        }
    }

    public func capture(id: UUID) throws -> SharedCapture? {
        try reader.read { db in
            try check(db)
            guard
                let row = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT CASE WHEN length(payload)<=262144 THEN payload END AS payload FROM sync_records WHERE id=?",
                    arguments: [id.uuidString])
            else { return nil }
            guard let data: Data = row["payload"] else { throw MCPFailure.capacity }
            let capture = try JSONDecoder().decode(SharedCapture.self, from: data)
            return capture.deleted ? nil : capture
        }
    }

    public func nextSequence(deviceID: UUID) throws -> Int64 {
        try reader.read { db in
            try check(db)
            let previous =
                try Int64.fetchOne(
                    db, sql: "SELECT sequence FROM sync_devices WHERE id=?",
                    arguments: [deviceID.uuidString]) ?? 0
            guard previous < Int64.max else { throw MCPFailure.capacity }
            return previous + 1
        }
    }
}
