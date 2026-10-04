import CapdSync
import Foundation
import GRDB
import Testing

@Suite("Synthetic phone reconciliation")
struct PhoneReconciliationTests {
    @Test("A complete original unsent chain aliases to Mac captures and retries exactly once")
    func completeUnsentChain() throws {
        try fixture { root in
            let mac = SharedCapture(
                source: CaptureSource(
                    kind: .text, contentHash: "same-synthetic-content", selection: "Mac source"))
            let server = try seed(mac, at: root)
            let phoneURL = root.appendingPathComponent("phone.sqlite")
            let phone = try SyncClient(
                databaseURL: phoneURL, blobDirectory: root.appendingPathComponent("phone-assets"))
            var source = SharedCapture(
                source: CaptureSource(
                    kind: .text, contentHash: mac.source.contentHash, selection: "Phone source"))
            source.manualTags = ["phone"]
            let create = try phone.enqueue(captureID: source.id, mutation: .create(source))
            let edit = try phone.enqueue(
                captureID: source.id, mutation: .edit(CaptureEdit(note: NoteEdit("Phone note"))))
            let rating = try phone.enqueue(
                captureID: source.id, mutation: .edit(CaptureEdit(rating: 5)))
            let operations = try phone.pendingOperations()
            #expect(operations.map(\.sequence) == [1, 2, 3])
            #expect(edit.predecessorID == create.id)
            #expect(rating.predecessorID == edit.id)
            let bytes = try pendingBytes(phoneURL)
            var receipts: [SyncReceipt] = []
            for operation in operations { receipts.append(try server.apply(operation)) }
            for (operation, receipt) in zip(operations, receipts) {
                #expect(try server.apply(operation) == receipt)
                #expect(receipt.operationID == operation.id)
                #expect(receipt.capture?.id == mac.id)
            }
            #expect(try server.baseline().deviceSequences[phone.deviceID] == 3)
            let accepted = try #require(try server.baseline().captures.first)
            #expect(accepted.seenCount == 8)
            #expect(accepted.note == "Phone note")
            #expect(accepted.rating == 5)
            #expect(accepted.manualTags == ["phone"])
            #expect(try phone.pendingOperations() == operations)
            #expect(try pendingBytes(phoneURL) == bytes)
            #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
                try SyncClient(
                    databaseURL: phoneURL,
                    blobDirectory: root.appendingPathComponent("phone-assets"),
                    binding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()))
            }
        }
    }

    @Test("Advanced sequence, unknown aliases and predecessor gaps require authority evidence")
    func missingHistory() throws {
        try fixture { root in
            let mac = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "Mac", selection: "Mac source"))
            let server = try seed(mac, at: root)
            let device = UUID()
            let advanced = SyncOperation(
                deviceID: device, sequence: 9, captureID: mac.id, baseRevision: 1,
                mutation: .edit(CaptureEdit(note: NoteEdit("Pending"))))
            #expect(throws: SyncError.outOfOrder(expected: 1)) { try server.apply(advanced) }
            #expect(try server.baseline().deviceSequences.isEmpty)
            let unknownAlias = SyncOperation(
                deviceID: device, sequence: 1, captureID: UUID(), baseRevision: 0,
                mutation: .edit(CaptureEdit(note: NoteEdit("Unresolved alias"))))
            #expect(try server.apply(unknownAlias).outcome == .missing)
            #expect(try server.baseline().deviceSequences[device] == 1)
            let missingPredecessor = SyncOperation(
                deviceID: device, sequence: 2, captureID: mac.id, baseRevision: 1,
                predecessorID: UUID(), mutation: .edit(CaptureEdit(note: NoteEdit("Dependent"))))
            #expect(throws: SyncError.invalidOperation) { try server.apply(missingPredecessor) }
            #expect(try server.baseline().deviceSequences[device] == 1)
            #expect(try server.baseline().captures.first?.seenCount == 7)
        }
    }

    @Test("Incompatible cursor epochs and unverified high-water refuse pull without changing work")
    func cursorAndHighWater() throws {
        try fixture { root in
            let mac = SharedCapture(
                source: CaptureSource(kind: .text, contentHash: "Mac", selection: "Mac source"))
            let server = try seed(mac, at: root)
            let phoneURL = root.appendingPathComponent("phone.sqlite")
            let phone = try SyncClient(
                databaseURL: phoneURL, blobDirectory: root.appendingPathComponent("phone-assets"))
            let local = SharedCapture(
                source: CaptureSource(
                    kind: .text, contentHash: "phone", selection: "Original phone pending"))
            try phone.enqueue(captureID: local.id, mutation: .create(local))
            let bytes = try pendingBytes(phoneURL)
            let database = try DatabaseQueue(path: phoneURL.path)
            try database.write { db in try db.execute(sql: "UPDATE sync_meta SET cursor=9") }
            #expect(throws: SyncError.invalidCursor) { try phone.pull(from: server) }
            #expect(try pendingBytes(phoneURL) == bytes)
            #expect(try phone.captures().map(\.id) == [local.id])
            try database.write { db in try db.execute(sql: "UPDATE sync_meta SET cursor=0") }
            let authorityDB = try DatabaseQueue(
                path: root.appendingPathComponent("server.sqlite").path)
            let pending = try phone.pendingOperations()
            let visible = try phone.captures()
            let baseline = try database.read { db in
                try Data.fetchAll(db, sql: "SELECT payload FROM sync_records ORDER BY id")
            }
            let metadata = try database.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM sync_meta")
            }
            try authorityDB.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_devices VALUES (?,1)",
                    arguments: [phone.deviceID.uuidString])
            }
            #expect(throws: SyncError.recoverySequenceCollision) { try phone.pull(from: server) }
            #expect(try pendingBytes(phoneURL) == bytes)
            #expect(try phone.pendingOperations() == pending)
            #expect(try phone.captures() == visible)
            #expect(
                try database.read { db in
                    try Data.fetchAll(db, sql: "SELECT payload FROM sync_records ORDER BY id")
                } == baseline)
            #expect(
                try database.read { db in
                    try Row.fetchOne(db, sql: "SELECT * FROM sync_meta")
                } == metadata)
            let futureRevision = SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: mac.id, baseRevision: 9,
                mutation: .edit(CaptureEdit(note: NoteEdit("Wrong epoch"))))
            #expect(throws: SyncError.invalidOperation) { try server.apply(futureRevision) }
        }
    }

    private func seed(_ record: SharedCapture, at root: URL) throws -> SyncServer {
        let url = root.appendingPathComponent("server.sqlite")
        let server = try SyncServer(
            databaseURL: url, blobDirectory: root.appendingPathComponent("server-assets"))
        var imported = record
        imported.revision = 1
        imported.seenCount = 7
        let payload = try JSONEncoder().encode(imported)
        let db = try DatabaseQueue(path: url.path)
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO sync_records VALUES (?,?)",
                arguments: [record.id.uuidString, payload])
            try db.execute(sql: "UPDATE sync_meta SET cursor=1,floor=1")
        }
        return server
    }

    private func pendingBytes(_ url: URL) throws -> [Data] {
        try DatabaseQueue(path: url.path).read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
    }

    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/capd-phone-reconciliation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
