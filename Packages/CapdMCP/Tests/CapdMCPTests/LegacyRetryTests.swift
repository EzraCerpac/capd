import CapdSync
import Foundation
import SQLite3
import XCTest

@testable import CapdMCP

final class LegacyRetryTests: XCTestCase {
    func testOldCreateAndEditRetryThroughToolboxWithoutRewritingReceipts() throws {
        let f = try MCPTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID()
        let create = f.create(id: id, text: "synthetic legacy text", note: "synthetic note")
        XCTAssertEqual(f.call("create_capture", create)["isError"], .bool(false))
        try removeRequestIdentity(f, operation: create["operation_id"]!.string!)
        let edit: Object = [
            "operation_id": .string(UUID().uuidString), "sequence": .number(2),
            "id": .string(id.uuidString), "base_revision": .number(1),
            "note": .string("synthetic changed note"), "rating": .number(4),
        ]
        XCTAssertEqual(f.call("edit_capture", edit)["isError"], .bool(false))
        try removeRequestIdentity(f, operation: edit["operation_id"]!.string!)
        let history = try receipts(f)
        let baseline = try f.server.baseline()
        for (name, arguments, revision) in [
            ("create_capture", create, 1), ("edit_capture", edit, 2),
        ] {
            for _ in 0..<3 {
                let reply = f.call(name, arguments)
                XCTAssertEqual(reply["isError"], .bool(false))
                XCTAssertEqual(reply["structuredContent"]?.object?["outcome"], .string("accepted"))
                XCTAssertEqual(
                    reply["structuredContent"]?.object?["receipt_revision"],
                    .number(Decimal(revision)))
                XCTAssertEqual(
                    reply["structuredContent"]?.object?["next_write_sequence"], .number(3))
            }
            var changed = arguments
            changed["note"] = .string("different request")
            XCTAssertEqual(
                f.call(name, changed)["structuredContent"]?.object?["error"],
                .string("operation_id_reused"))
        }
        XCTAssertEqual(try receipts(f), history)
        XCTAssertEqual(try f.server.baseline().cursor, baseline.cursor)
        XCTAssertEqual(try f.server.baseline().captures, baseline.captures)
        XCTAssertEqual(try f.server.baseline().deviceSequences, baseline.deviceSequences)
        _ = try f.server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: id, baseRevision: 2,
                mutation: .delete))
        let deletedHistory = try receipts(f)
        let deletedCursor = try f.server.baseline().cursor
        let reply = f.call("create_capture", create)
        XCTAssertEqual(reply["isError"], .bool(false))
        XCTAssertNil(reply["structuredContent"]?.object?["capture"])
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(reply), as: UTF8.self).contains(
                "synthetic legacy text"))
        XCTAssertEqual(try receipts(f), deletedHistory)
        XCTAssertEqual(try f.server.baseline().cursor, deletedCursor)
        XCTAssertEqual(try f.store.nextSequence(deviceID: f.device), 3)
    }

    private func receipts(_ f: MCPTests.Fixture) throws -> [[Data]] {
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(f.directory.appendingPathComponent("authority.sqlite").path, &database),
            SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database, "SELECT operation,receipt FROM sync_receipts ORDER BY id", -1, &statement,
                nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var result: [[Data]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                (0...1).map { column in
                    Data(
                        bytes: sqlite3_column_blob(statement, Int32(column))!,
                        count: Int(sqlite3_column_bytes(statement, Int32(column))))
                })
        }
        return result
    }

    private func removeRequestIdentity(_ f: MCPTests.Fixture, operation: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(f.directory.appendingPathComponent("authority.sqlite").path, &database),
            SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database, "SELECT operation FROM sync_receipts WHERE id=?", -1, &statement, nil),
            SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        XCTAssertEqual(sqlite3_bind_text(statement, 1, operation, -1, transient), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let data = Data(
            bytes: sqlite3_column_blob(statement, 0)!,
            count: Int(sqlite3_column_bytes(statement, 0)))
        sqlite3_finalize(statement)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(old.removeValue(forKey: "requestIdentity"))
        let legacy = try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys])
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database, "UPDATE sync_receipts SET operation=? WHERE id=?", -1, &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(
            legacy.withUnsafeBytes {
                sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient)
            }, SQLITE_OK)
        XCTAssertEqual(sqlite3_bind_text(statement, 2, operation, -1, transient), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        XCTAssertEqual(sqlite3_changes(database), 1)
    }
}
