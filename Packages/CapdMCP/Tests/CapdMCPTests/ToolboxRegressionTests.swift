import CapdSync
import Foundation
import SQLite3
import XCTest

@testable import CapdMCP

final class ToolboxRegressionTests: XCTestCase {
    func testTruncationReturnsExactUTF8Prefixes() throws {
        let f = try MCPTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        for (full, budget) in [(false, 768), (true, 24576)] {
            let id = UUID()
            let prefix = String(repeating: "a", count: budget - 1)
            let value = prefix + "😀é"
            let capture = SharedCapture(
                id: id, source: CaptureSource(kind: .text, selection: full ? value : nil),
                note: full ? nil : value)
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: id, baseRevision: 0,
                    mutation: .create(capture)))
            let result = f.call(
                full ? "get_capture" : "list_recent", full ? ["id": .string(id.uuidString)] : [:])[
                    "structuredContent"]?.object
            let projected: Object?
            if full {
                projected = result?["capture"]?.object
            } else if case .array(let captures) = result?["captures"] {
                projected = captures.first { $0.object?["id"] == .string(id.uuidString) }?.object
            } else {
                projected = nil
            }
            XCTAssertEqual(projected?[full ? "selection" : "note"], .string(prefix))
            XCTAssertEqual(projected?["truncated"], .bool(true))
        }
    }

    func testEmptyTagOnlyEditsDoNotConsumeSequenceOrChangeAuthority() throws {
        let f = try MCPTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID()
        _ = f.call("create_capture", f.create(id: id))
        let before = try f.server.baseline()
        for keys in [["add_tags"], ["remove_tags"], ["add_tags", "remove_tags"]] {
            var edit = editArguments(id: id)
            for key in keys { edit[key] = .array([]) }
            XCTAssertEqual(f.call("edit_capture", edit)["isError"], .bool(true))
        }
        XCTAssertEqual(try f.server.baseline().cursor, before.cursor)
        XCTAssertEqual(try f.server.baseline().captures, before.captures)
        XCTAssertEqual(try f.store.nextSequence(deviceID: f.device), 2)
        var realEdit = editArguments(id: id)
        realEdit["add_tags"] = .array([])
        realEdit["rating"] = .number(4)
        XCTAssertEqual(f.call("edit_capture", realEdit)["isError"], .bool(false))
    }

    func testOversizedConflictResolutionReportsCapacityWithoutAddingConflict() throws {
        let f = try MCPTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID()
        _ = f.call("create_capture", f.create(id: id, note: "original"))
        for i in 0...20 {
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: id, baseRevision: 1,
                    mutation: .edit(CaptureEdit(note: NoteEdit("conflict \(i)")))))
        }
        let before = try f.server.baseline()
        let capture = try XCTUnwrap(before.captures.first)
        XCTAssertEqual(capture.noteConflicts.count, 21)
        let projection = f.call("get_capture", ["id": .string(id.uuidString)])[
            "structuredContent"]?.object?["capture"]?.object
        XCTAssertEqual(projection?["note_conflict_count"], .number(21))
        XCTAssertEqual(projection?["note_conflict_resolution_available"], .bool(false))
        for count in [20, 21] {
            var edit = editArguments(id: id, revision: capture.revision)
            edit["note"] = .string("resolved")
            edit["resolve_note_operations"] = .array(
                capture.noteConflicts.prefix(count).map { .string($0.operationID.uuidString) })
            XCTAssertEqual(
                f.call("edit_capture", edit)["structuredContent"]?.object?["error"],
                .string("note_conflict_resolution_capacity_exceeded"))
            if count == 20 {
                edit["sequence"] = .number(3)
                XCTAssertEqual(
                    f.call("edit_capture", edit)["structuredContent"]?.object?["error"],
                    .string("sequence_conflict_expected_2"))
            }
        }
        XCTAssertEqual(try f.server.baseline().cursor, before.cursor)
        XCTAssertEqual(try f.server.baseline().captures, before.captures)
        XCTAssertEqual(try f.store.nextSequence(deviceID: f.device), 2)
    }

    func testOriginalArgumentsRemainExactAcrossToolboxReopen() throws {
        for variant in 0...3 {
            let f = try MCPTests.Fixture()
            defer { try? FileManager.default.removeItem(at: f.directory) }
            var original = f.create(id: UUID(), operation: UUID())
            original["rating"] = .number(3)
            original["note"] = .null
            XCTAssertEqual(f.call("create_capture", original)["isError"], .bool(false))
            var changed = original
            switch variant {
            case 0: changed.removeValue(forKey: "rating")
            case 1: changed.removeValue(forKey: "note")
            case 2: changed["id"] = .string(original["id"]!.string!.lowercased())
            default: changed["created_at"] = .string("2026-10-04T10:00:00+00:00")
            }
            let reopened = try MCPToolbox(store: f.store, authority: f.server)
            XCTAssertEqual(
                reopened.call(name: "create_capture", arguments: original, grant: f.grant).object?[
                    "isError"], .bool(false))
            let rejected = reopened.call(name: "create_capture", arguments: changed, grant: f.grant)
            XCTAssertEqual(
                rejected.object?["structuredContent"]?.object?["error"],
                .string("operation_id_reused"))
            XCTAssertEqual(try f.store.nextSequence(deviceID: f.device), 2)
            XCTAssertEqual(try f.server.baseline().captures.count, 1)
        }
    }

    func testCommittedResolutionReplaysAfterConflictCapacityChanges() throws {
        let f = try MCPTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let id = UUID()
        _ = f.call("create_capture", f.create(id: id, note: "original"))
        for i in 0...1 {
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: id, baseRevision: 1,
                    mutation: .edit(CaptureEdit(note: NoteEdit("initial conflict \(i)")))))
        }
        let current = try XCTUnwrap(try f.server.baseline().captures.first)
        var resolution = editArguments(id: id, revision: current.revision)
        resolution["note"] = .string("resolved")
        resolution["resolve_note_operations"] = .array(
            current.noteConflicts.map { .string($0.operationID.uuidString) })
        XCTAssertEqual(f.call("edit_capture", resolution)["isError"], .bool(false))
        let resolved = try XCTUnwrap(try f.server.baseline().captures.first)
        for i in 0...20 {
            _ = try f.server.apply(
                SyncOperation(
                    deviceID: UUID(), sequence: 1, captureID: id, baseRevision: resolved.revision,
                    mutation: .edit(CaptureEdit(note: NoteEdit("later conflict \(i)")))))
        }
        let before = try f.server.baseline()
        XCTAssertEqual(before.captures.first?.noteConflicts.count, 21)
        XCTAssertEqual(f.call("edit_capture", resolution)["isError"], .bool(false))
        XCTAssertEqual(try f.server.baseline().cursor, before.cursor)
        XCTAssertEqual(try f.server.baseline().captures, before.captures)
    }

    func testReceiptRequestIdentityContainsOnlyCanonicalDigest() throws {
        let f = try MCPTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let create = f.create(id: UUID(), text: "private text", note: "private note")
        XCTAssertEqual(f.call("create_capture", create)["isError"], .bool(false))
        var edit = editArguments(id: UUID(uuidString: create["id"]!.string!)!)
        edit["note"] = .string("private edit")
        edit["add_tags"] = .array([.string("private tag")])
        XCTAssertEqual(f.call("edit_capture", edit)["isError"], .bool(false))
        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(f.directory.appendingPathComponent("authority.sqlite").path, &db),
            SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db, "SELECT operation FROM sync_receipts ORDER BY rowid", -1, &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        for (name, arguments) in [("create_capture", create), ("edit_capture", edit)] {
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            let bytes = try XCTUnwrap(sqlite3_column_blob(statement, 0))
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            let operation = try JSONDecoder().decode(SyncOperation.self, from: data)
            let expected = try MCPToolbox.requestIdentity(name: name, arguments: arguments)
            XCTAssertEqual(operation.requestIdentity, expected)
            let digest = try XCTUnwrap(operation.requestIdentity?.object?["sha256"]?.string)
            XCTAssertEqual(digest.count, 64)
            XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
            XCTAssertEqual(operation.requestIdentity?.object?.count, 1)
            var reordered: Object = [:]
            for key in arguments.keys.sorted().reversed() { reordered[key] = arguments[key] }
            XCTAssertEqual(
                try MCPToolbox.requestIdentity(name: name, arguments: reordered), expected)
            XCTAssertEqual(f.call(name, reordered)["isError"], .bool(false))
            var changed = arguments
            changed["note"] = .string("changed content")
            XCTAssertEqual(
                f.call(name, changed)["structuredContent"]?.object?["error"],
                .string("operation_id_reused"))
        }
    }

    private func editArguments(id: UUID, revision: Int64 = 1) -> Object {
        [
            "operation_id": .string(UUID().uuidString), "sequence": .number(2),
            "id": .string(id.uuidString), "base_revision": .number(Decimal(revision)),
        ]
    }
}
