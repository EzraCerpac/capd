import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdKit

struct MacDiscoveryProjectionTests {
    @Test func nativeDiscoveryDoesNotDecodeBodyOrEnrichmentPayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        let store = try Store(paths: paths)
        try store.dbPool.write { db in
            var manual = Capture(
                kind: .text, title: "Explicit synthetic title", selection: "Private source",
                tags: "manual 草", tagsVersion: Capture.pinnedTagsVersion, createdAt: Date())
            try manual.insert(db)
            var generated = Capture(
                kind: .link, title: "Other synthetic title", tags: "generated",
                tagsVersion: 1, createdAt: Date())
            try generated.insert(db)
            try db.execute(sql: "PRAGMA ignore_check_constraints=ON")
            try db.execute(
                sql: """
                    UPDATE captures SET body=zeroblob(2097152), ocr_text=zeroblob(2097152),
                        note=zeroblob(2097152), enrichment_state='unused-invalid-state'
                    """)
            try db.execute(sql: "PRAGMA ignore_check_constraints=OFF")
        }
        let snapshot = try? MacDiscoverySnapshot.load(paths: paths, localLibraryID: UUID())
        #expect(
            snapshot?.captures.map(\.title) == [
                "Explicit synthetic title", "Other synthetic title",
            ])
        #expect(snapshot?.captures.map(\.manualTags) == [["manual", "草"], []])
    }

    @Test func sharedDiscoveryProjectsMetadataWithoutDecodingGeneratedOrNotePayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let device = UUID()
        let store = try Store(paths: paths, syncBinding: binding, deviceID: device)
        let enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.invalid/v1/sync")!, binding: binding,
            deviceID: device)
        try MacSyncConfiguration(enrollment: enrollment).install(paths: paths)
        var shared = SharedCapture(
            source: CaptureSource(kind: .text, title: "Shared explicit title"))
        shared.manualTags = ["manual", "草"]
        shared.revision = 7
        var document =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as! [String: Any]
        let unused = String(repeating: "x", count: 2_097_152)
        document["generated"] = ["body": unused, "ocrText": unused, "tags": ["generated"]]
        document["note"] = unused
        document["noteConflicts"] = "unused invalid conflicts"
        let payload = try JSONSerialization.data(withJSONObject: document)
        try store.dbPool.write { db in
            var local = Capture(kind: .text, title: "Stale local title", createdAt: Date())
            try local.insert(db)
            try db.execute(
                sql: "INSERT INTO sync_capture_ids VALUES (?,?)",
                arguments: [local.id, shared.id.uuidString])
            try db.execute(
                sql: "INSERT INTO sync_visible (id,payload) VALUES (?,?)",
                arguments: [shared.id.uuidString, payload])
        }
        let snapshot = try? MacDiscoverySnapshot.load(paths: paths, localLibraryID: UUID())
        #expect(snapshot?.libraryID == binding.libraryID)
        #expect(snapshot?.captures.map(\.id) == [shared.id])
        #expect(snapshot?.captures.first?.title == "Shared explicit title")
        #expect(snapshot?.captures.first?.manualTags == ["manual", "草"])
        #expect(snapshot?.captures.first?.revision == 7)
    }

    @Test func oversizedNativeCountRefusesBeforeDecodingAnyCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = StoragePaths(root: root)
        let store = try Store(paths: paths)
        try store.dbPool.write { db in
            for _ in 0..<1001 {
                var capture = Capture(kind: .text, title: "Synthetic", createdAt: Date())
                try capture.insert(db)
            }
            try db.execute(sql: "PRAGMA ignore_check_constraints=ON")
            try db.execute(sql: "UPDATE captures SET kind='invalid-retained-kind'")
            try db.execute(sql: "PRAGMA ignore_check_constraints=OFF")
        }
        var limited = false
        do {
            _ = try MacDiscoverySnapshot.load(paths: paths, localLibraryID: UUID())
        } catch MacDiscoveryError.snapshotTooLarge { limited = true } catch {}
        #expect(limited)
    }
    @Test(arguments: [false, true])
    func unicodeSourceTitlesAndManualTagsPreservePrivacy(shared: Bool) throws {
        let fixture = try ProjectionLibrary(shared: shared)
        defer { fixture.remove() }
        let selection = "\u{2003}\u{00a0}" + String(repeating: "👩🏽‍💻草e\u{301}", count: 1000)
        let derived = String(selection.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let tags = (0..<60).map { "manual\($0)" }
        _ = try fixture.insert(
            CaptureSource(kind: .text, title: derived, selection: selection), tags: tags)
        _ = try fixture.insert(
            CaptureSource(kind: .text, title: "Explicit title", selection: selection))
        _ = try fixture.insert(CaptureSource(kind: .link, title: derived, selection: selection))
        let snapshot = try fixture.snapshot()
        #expect(snapshot.captures.map(\.title) == ["Saved text", "Explicit title", derived])
        #expect(snapshot.captures.first?.manualTags == tags)
    }

    @Test(arguments: [false, true])
    func ambiguousTruncatedGraphemePrefixFailsClosed(shared: Bool) throws {
        let fixture = try ProjectionLibrary(shared: shared)
        defer { fixture.remove() }
        let selection = "e" + String(repeating: "\u{301}", count: 3000) + "Private following source"
        _ = try fixture.insert(
            CaptureSource(kind: .text, title: "Explicit short title", selection: selection))
        #expect(fixture.isLimited())
    }

    @Test(arguments: [false, true])
    func unusedLargeURLAndHostAreIgnoredButNeededURLKeepsItsExactFallback(shared: Bool) throws {
        let fixture = try ProjectionLibrary(shared: shared)
        defer { fixture.remove() }
        let large = String(repeating: "x", count: 524_288)
        _ = try fixture.insert(
            CaptureSource(kind: .link, url: large, host: large, title: "Explicit"))
        _ = try fixture.insert(
            CaptureSource(
                kind: .link, url: "https://example.invalid/" + String(repeating: "p", count: 20_000)
            ))
        let snapshot = try fixture.snapshot()
        #expect(snapshot.captures.map(\.title) == ["Explicit", "example.invalid"])
    }

    @Test(arguments: [false, true])
    func retainedMetadataBudgetsAreCheckedBeforeReturningRows(shared: Bool) throws {
        let fixture = try ProjectionLibrary(shared: shared)
        defer { fixture.remove() }
        _ = try fixture.insert(
            CaptureSource(kind: .link, title: String(repeating: "t", count: 4096)))
        #expect(try fixture.snapshot().captures.first?.title.utf8.count == 4096)
        _ = try fixture.insert(
            CaptureSource(kind: .link, title: String(repeating: "t", count: 4097)))
        #expect(fixture.isLimited())
    }

    @Test(arguments: [false, true])
    func oversizedManualTagsFailClosed(shared: Bool) throws {
        let fixture = try ProjectionLibrary(shared: shared)
        defer { fixture.remove() }
        _ = try fixture.insert(
            CaptureSource(kind: .link, title: "Explicit"),
            tags: [String(repeating: "t", count: 16_385)])
        #expect(fixture.isLimited())
    }

    @Test func nativeAggregateMetadataIsBounded() throws {
        let fixture = try ProjectionLibrary(shared: false)
        defer { fixture.remove() }
        try fixture.store.dbPool.write { db in
            for _ in 0..<1000 {
                var capture = Capture(
                    kind: .link, title: "Explicit", tags: String(repeating: "t", count: 8500),
                    tagsVersion: Capture.pinnedTagsVersion, createdAt: Date())
                try capture.insert(db)
            }
        }
        #expect(fixture.isLimited())
    }

    @Test(arguments: [false, true])
    func rawSharedPayloadLimitsPrecedeJSONParsing(aggregate: Bool) throws {
        let fixture = try ProjectionLibrary(shared: true)
        defer { fixture.remove() }
        for _ in 0..<(aggregate ? 5 : 1) {
            _ = try fixture.insert(CaptureSource(kind: .text, title: "Explicit"))
        }
        try fixture.store.dbPool.write { db in
            try db.execute(
                sql: "UPDATE sync_visible SET payload=zeroblob(?)",
                arguments: [aggregate ? 13_421_773 : 16_777_217])
        }
        #expect(fixture.isLimited())
    }

    @Test(arguments: ["mapping", "alias", "payload-id", "kind", "manual-tags", "revision"])
    func invalidBoundDiscoveryIdentitiesAndRetainedFieldsFailClosed(mode: String) throws {
        let fixture = try ProjectionLibrary(shared: true)
        defer { fixture.remove() }
        let id = try fixture.insert(CaptureSource(kind: .text, title: "Explicit"))!
        try fixture.store.dbPool.write { db in
            switch mode {
            case "mapping": try db.execute(sql: "UPDATE sync_capture_ids SET global_id='invalid'")
            case "alias":
                try db.execute(
                    sql: "INSERT INTO sync_aliases (id,canonical) VALUES (?,'invalid')",
                    arguments: [id.uuidString])
            default:
                let payload = try Data.fetchOne(db, sql: "SELECT payload FROM sync_visible")!
                var document = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
                switch mode {
                case "payload-id": document["id"] = UUID().uuidString
                case "kind":
                    var source = document["source"] as! [String: Any]
                    source["kind"] = "invalid"
                    document["source"] = source
                case "manual-tags": document["manualTags"] = [1]
                default: document["revision"] = -1
                }
                try db.execute(
                    sql: "UPDATE sync_visible SET payload=?",
                    arguments: [try JSONSerialization.data(withJSONObject: document)])
            }
        }
        #expect((try? fixture.snapshot()) == nil)
    }

    @Test func ambiguousCaseDuplicateBoundIdentitiesFailClosed() throws {
        let fixture = try ProjectionLibrary(shared: true)
        defer { fixture.remove() }
        let id = try fixture.insert(CaptureSource(kind: .text, title: "Direct canonical"))!
        let alias = UUID()
        try fixture.store.dbPool.write { db in
            let payload = try Data.fetchOne(db, sql: "SELECT payload FROM sync_visible")!
            try db.execute(
                sql: "INSERT INTO sync_visible (id,payload) VALUES (?,?)",
                arguments: [id.uuidString.lowercased(), payload])
            var capture = Capture(kind: .text, title: "Alias local", createdAt: Date())
            try capture.insert(db)
            try db.execute(
                sql: "INSERT INTO sync_capture_ids (local_id,global_id) VALUES (?,?)",
                arguments: [capture.id, alias.uuidString])
            try db.execute(
                sql: "INSERT INTO sync_aliases (id,canonical) VALUES (?,?)",
                arguments: [alias.uuidString, id.uuidString.lowercased()])
        }
        #expect(throws: MacDiscoveryError.self) { try fixture.snapshot() }
    }

    @Test func deletedSharedRowsDoNotConsumeTheCanonicalLimit() throws {
        let fixture = try ProjectionLibrary(shared: true)
        defer { fixture.remove() }
        try fixture.store.dbPool.write { db in
            for index in 0..<1010 {
                var shared = SharedCapture(source: CaptureSource(kind: .text, title: "Synthetic"))
                shared.deleted = index >= 1000
                var local = Capture(kind: .text, title: "Local", createdAt: Date())
                try local.insert(db)
                try db.execute(
                    sql: "INSERT INTO sync_capture_ids (local_id,global_id) VALUES (?,?)",
                    arguments: [local.id, shared.id.uuidString])
                try db.execute(
                    sql: "INSERT INTO sync_visible (id,payload) VALUES (?,?)",
                    arguments: [shared.id.uuidString, try JSONEncoder().encode(shared)])
            }
        }
        #expect(try fixture.snapshot().captures.count == 1000)
    }

}

private struct ProjectionLibrary {
    let root: URL
    let paths: StoragePaths
    let store: Store
    let shared: Bool

    init(shared: Bool) throws {
        self.shared = shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = StoragePaths(root: root)
        if shared {
            let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
            let device = UUID()
            store = try Store(paths: paths, syncBinding: binding, deviceID: device)
            try MacSyncConfiguration(
                enrollment: SyncEnrollment(
                    endpoint: URL(string: "https://sync.example.invalid/v1/sync")!,
                    binding: binding, deviceID: device)
            ).install(paths: paths)
        } else {
            store = try Store(paths: paths)
        }
    }

    func insert(_ source: CaptureSource, tags: [String] = []) throws -> UUID? {
        try store.dbPool.write { db in
            var capture = Capture(
                kind: CaptureKind(rawValue: source.kind.rawValue)!, url: source.url,
                host: source.host, title: source.title, selection: source.selection,
                tags: tags.isEmpty ? nil : tags.joined(separator: " "),
                tagsVersion: tags.isEmpty ? 0 : Capture.pinnedTagsVersion, createdAt: Date())
            try capture.insert(db)
            guard shared else { return nil }
            var record = SharedCapture(source: source)
            record.manualTags = tags
            try db.execute(
                sql: "INSERT INTO sync_capture_ids (local_id,global_id) VALUES (?,?)",
                arguments: [capture.id, record.id.uuidString])
            try db.execute(
                sql: "INSERT INTO sync_visible (id,payload) VALUES (?,?)",
                arguments: [record.id.uuidString, try JSONEncoder().encode(record)])
            return record.id
        }
    }

    func snapshot() throws -> MacDiscoverySnapshot {
        try .load(paths: paths, localLibraryID: UUID())
    }
    func isLimited() -> Bool {
        do {
            _ = try snapshot()
            return false
        } catch MacDiscoveryError.snapshotTooLarge { return true } catch { return false }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
