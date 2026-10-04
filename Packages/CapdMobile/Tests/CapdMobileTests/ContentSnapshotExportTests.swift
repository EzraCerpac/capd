import CapdSync
import Foundation
import GRDB
import Testing

@testable import CapdMobile

@Test func advancedPhoneSnapshotExportsVisibleContentWithoutChangingOriginalDatabaseOrOutbox()
    throws
{
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "capd-phone-content-export-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("old-phone/captures.sqlite")
    let mobile = try MobileStore(url: sourceURL)
    let originalAuthority = try SyncServer(
        databaseURL: root.appendingPathComponent("original-authority.sqlite"),
        blobDirectory: root.appendingPathComponent("original-authority-blobs"))
    let date = Date(timeIntervalSinceReferenceDate: 123_456_789.12345679)
    var local = MobileCapture(
        kind: .text, title: "Synthetic populated phone", selection: "Preserved phone content",
        note: "Accepted original note", createdAt: date)
    local.metadata = CaptureMetadata(
        updatedAt: date.addingTimeInterval(1), reminderAt: date.addingTimeInterval(2),
        sourceAppBundleID: "test.original-phone", unknownFields: ["future": .string("retained")])
    try mobile.save(local)
    try mobile.push(to: originalAuthority)
    let peer = try SyncClient(
        databaseURL: root.appendingPathComponent("original-peer.sqlite"),
        blobDirectory: root.appendingPathComponent("peer-blobs"))
    try peer.pull(from: originalAuthority)
    try peer.enqueue(
        captureID: local.id,
        mutation: .edit(
            CaptureEdit(
                generatedPatch: GeneratedContentPatch(
                    body: .set("Accepted generated body"), ocrText: .set("Accepted OCR"),
                    tags: ["generated"]))))
    try peer.push(to: originalAuthority)
    try mobile.pull(from: originalAuthority)
    try mobile.update(id: local.id, note: "Exact offline phone note", tags: ["manual"])
    let second = try CaptureInput.make(text: "Second offline phone capture", isLink: false)
    try mobile.save(second)
    let pending = try mobile.pending()
    #expect(pending.map(\.sequence) == [2, 3])
    let db = try DatabaseQueue(path: sourceURL.path)
    func sourceState() throws -> [String: [Row]] {
        try db.read { connection in
            try Dictionary(
                uniqueKeysWithValues: [
                    "sync_meta", "sync_records", "sync_visible", "sync_outbox", "sync_aliases",
                    "sync_rejections", "mobile_captures", "grdb_migrations",
                ].map {
                    ($0, try Row.fetchAll(connection, sql: "SELECT * FROM \($0) ORDER BY 1"))
                })
        }
    }
    func sourceFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for suffix in ["", "-wal"] {
            let url = URL(fileURLWithPath: sourceURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                files[suffix] = try Data(contentsOf: url)
            }
        }
        return files
    }
    let state = try sourceState()
    let files = try sourceFiles()
    let oldDevice = mobile.deviceID
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let snapshotID = UUID()
    let snapshot = try mobile.contentSnapshotImport(snapshotID: snapshotID, targetBinding: binding)
    #expect(snapshot.sourceDeviceID == oldDevice)
    #expect(snapshot.captures.count == 2)
    let exported = try #require(snapshot.captures.first { $0.id == local.id })
    #expect(exported.note == "Exact offline phone note")
    #expect(exported.createdAt == date)
    #expect(exported.metadata == local.metadata)
    #expect(exported.generated.body == "Accepted generated body")
    #expect(exported.generated.ocrText == "Accepted OCR")
    #expect(exported.generated.tags == ["generated"])
    #expect(exported.manualTags == ["manual"])
    #expect(
        try mobile.contentSnapshotImport(snapshotID: snapshotID, targetBinding: binding) == snapshot
    )
    #expect(try sourceState() == state)
    #expect(try sourceFiles() == files)
    #expect(try mobile.pending() == pending)
    #expect(mobile.deviceID == oldDevice)
    let newAuthority = try SyncServer(
        databaseURL: root.appendingPathComponent("new-authority.sqlite"),
        blobDirectory: root.appendingPathComponent("new-authority-blobs"),
        libraryID: binding.libraryID, serviceID: binding.serviceID)
    let preview = try newAuthority.previewContentSnapshotImport(snapshot)
    let receipt = try newAuthority.importContentSnapshot(snapshot, preview: preview)
    #expect(Set(receipt.items.map(\.id)).isDisjoint(with: pending.map(\.id)))
    #expect(try newAuthority.baseline().deviceSequences.isEmpty)
    #expect(try sourceState() == state)
    #expect(try sourceFiles() == files)
    #expect(try mobile.pending() == pending)
    #expect(throws: SyncBindingError.enrollmentRequiresEmptyLibrary) {
        try SyncClient(
            writer: db,
            blobs: BlobStore(
                directory: sourceURL.deletingLastPathComponent().appendingPathComponent("assets")),
            binding: binding)
    }
    #expect(try mobile.pending() == pending)
    #expect(try sourceState() == state)
    #expect(try sourceFiles() == files)
    #expect(try mobile.search("accepted").map(\.id) == [local.id])
}
