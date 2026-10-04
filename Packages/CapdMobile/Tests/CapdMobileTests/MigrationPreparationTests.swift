#if os(macOS)
    import CapdSync
    import Foundation
    import GRDB
    import Testing

    @testable import CapdMobile

    @Test(
        "Populated mobile preparation preserves exact queued bytes, identity, tags and FTS without enrolling"
    )
    func populatedMobileMigrationPreparation() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/capd-mobile-migration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("phone-fixture")
        let url = source.appendingPathComponent("captures.sqlite")
        let mobile = try MobileStore(url: url)
        try Data("synthetic-capd-library-v1\n".utf8).write(
            to: source.appendingPathComponent(".capd-synthetic-fixture"))
        let server = try SyncServer(
            databaseURL: root.appendingPathComponent("old-authority.sqlite"),
            blobDirectory: root.appendingPathComponent("old-assets"))
        let capture = try CaptureInput.make(
            text: "Synthetic kestrel source", note: "Original", isLink: false)
        try mobile.save(capture)
        try mobile.push(to: server)
        let peer = try SyncClient(
            databaseURL: root.appendingPathComponent("peer.sqlite"),
            blobDirectory: root.appendingPathComponent("peer-assets"))
        try peer.pull(from: server)
        try peer.enqueue(
            captureID: capture.id,
            mutation: .edit(
                CaptureEdit(
                    generated: GeneratedContent(
                        body: "Pangolin body", ocrText: "Axolotl OCR", tags: ["generated"]))))
        try peer.push(to: server)
        try mobile.pull(from: server)
        try mobile.update(id: capture.id, note: "Exact pending note", tags: ["manual"])
        try mobile.save(CaptureInput.make(text: "Second offline capture", isLink: false))
        let before = try mobile.search()
        let operations = try mobile.pending()
        #expect(operations.map(\.sequence) == [2, 3])
        let database = try DatabaseQueue(path: url.path)
        let bytes = try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let archive = root.appendingPathComponent("archive")
        let arguments = [
            "prepare-enrollment", source.path, "--destination", archive.path,
            "--library-id", binding.libraryID.uuidString, "--service-id",
            binding.serviceID.uuidString,
        ]
        let data = try mobileMigrationCommand(arguments)
        #expect(try mobileMigrationCommand(arguments) == data)
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let plan = try #require(result["enrollment"] as? [String: Any])
        #expect(plan["activation"] as? String == "blocked")
        #expect(plan["completeSequenceReplayCandidate"] as? Bool == false)
        let state = try #require(plan["deviceState"] as? [String: Any])
        #expect(state["device"] as? String == mobile.deviceID.uuidString)
        #expect(state["sequence"] as? Int == 3)
        let restored = root.appendingPathComponent("restored")
        _ = try mobileMigrationCommand(["restore", archive.path, "--destination", restored.path])
        let restoredURL = restored.appendingPathComponent("captures.sqlite")
        let reopened = try MobileStore(url: restoredURL)
        #expect(reopened.deviceID == mobile.deviceID)
        #expect(try reopened.pending() == operations)
        #expect(try reopened.search() == before)
        #expect(try reopened.search("pangolin").map(\.id) == [capture.id])
        #expect(try reopened.search("manual").map(\.id) == [capture.id])
        #expect(try reopened.search("generated").map(\.id) == [capture.id])
        let restoredDB = try DatabaseQueue(path: restoredURL.path)
        #expect(
            try restoredDB.read { db in
                try Data.fetchAll(db, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
            } == bytes)
        #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
            try SyncClient(
                writer: restoredDB,
                blobs: BlobStore(directory: restored.appendingPathComponent("assets")),
                binding: binding)
        }
        let emptyServer = try SyncServer(
            databaseURL: root.appendingPathComponent("empty-server.sqlite"),
            blobDirectory: root.appendingPathComponent("empty-server-assets"))
        #expect(throws: SyncError.outOfOrder(expected: 1)) { try emptyServer.apply(operations[0]) }
        #expect(try mobile.pending() == operations)
        #expect(try mobile.search() == before)
    }

    private func mobileMigrationCommand(_ arguments: [String]) throws -> Data {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments =
            [repo.appendingPathComponent("Scripts/synthetic_library_migration.py").path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "SyntheticMigration", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return data
    }
#endif
