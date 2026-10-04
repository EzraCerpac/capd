import Foundation
import GRDB
import Testing

@testable import CapdSync

@Suite("Independent tagging processing patches")
struct TaggingProcessingPatchTests {
    @Test func staleCompletionMarkerPreservesNewerServerBodyOCRAndTags() throws {
        let f = try ProcessingFixture()
        defer { f.clean() }
        let client = try f.client("offline")
        var original = f.capture()
        original.generated = GeneratedContent(
            body: "Old body", ocrText: "Old OCR", tags: ["old tag"])
        original.generated.unknownFields = ["future": .string("retained")]
        try client.enqueue(captureID: original.id, mutation: .create(original))
        try client.push(to: f.server)
        let marker = try client.enqueue(
            captureID: original.id,
            mutation: .edit(
                CaptureEdit(
                    generatedPatch: GeneratedContentPatch(
                        taggingProcessing: .processed(inputFingerprint: "exact-old-input")))))
        let bytes = try f.outbox("offline")
        let peer = try f.client("peer")
        try peer.pull(from: f.server)
        try peer.enqueue(
            captureID: original.id,
            mutation: .edit(
                CaptureEdit(
                    generatedPatch: GeneratedContentPatch(
                        body: .set("Newer server body"), ocrText: .set("Newer server OCR"),
                        tags: ["newer server tag"]))))
        try peer.push(to: f.server)
        #expect(try f.outbox("offline") == bytes)
        #expect(try f.client("offline").pendingOperations() == [marker])
        let receipt = try #require(try client.push(to: f.server).first)
        let generated = try #require(receipt.capture?.generated)
        #expect(generated.body == "Newer server body")
        #expect(generated.ocrText == "Newer server OCR")
        #expect(generated.tags == ["newer server tag"])
        #expect(generated.unknownFields["future"] == .string("retained"))
        #expect(generated.taggingProcessed == true)
        #expect(generated.taggingInputFingerprint == "exact-old-input")
        #expect(generated.taggingInputFingerprint != "exact-newer-input")
        try client.enqueue(
            captureID: original.id,
            mutation: .edit(
                CaptureEdit(generatedPatch: GeneratedContentPatch(taggingProcessing: .pending))))
        try client.push(to: f.server)
        let pending = try #require(try client.captures().first?.generated)
        #expect(pending.taggingProcessed == false)
        #expect(pending.taggingInputFingerprint == nil)
        #expect(pending.body == generated.body)
        #expect(pending.ocrText == generated.ocrText)
        #expect(pending.tags == generated.tags)
    }

    @Test func zeroTagCompletionOmissionAndLegacyReplacementKeepProcessingIndependent() throws {
        let f = try ProcessingFixture()
        defer { f.clean() }
        let client = try f.client("client")
        var capture = f.capture()
        capture.generated = GeneratedContent(body: "Kept body", ocrText: "Kept OCR", tags: [])
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        try client.push(to: f.server)
        #expect(try client.captures().first?.generated.taggingProcessed == nil)
        try client.enqueue(
            captureID: capture.id,
            mutation: .edit(
                CaptureEdit(
                    generatedPatch: GeneratedContentPatch(
                        taggingProcessing: .processed(inputFingerprint: "exact-zero-tag-input")))))
        try client.push(to: f.server)
        let complete = try #require(try client.captures().first?.generated)
        #expect(complete.tags.isEmpty)
        #expect(complete.body == capture.generated.body)
        #expect(complete.ocrText == capture.generated.ocrText)
        #expect(complete.taggingProcessed == true)
        #expect(complete.taggingInputFingerprint == "exact-zero-tag-input")
        for patch in [GeneratedContentPatch(), GeneratedContentPatch(body: .set("New body"))] {
            try client.enqueue(
                captureID: capture.id, mutation: .edit(CaptureEdit(generatedPatch: patch)))
            try client.push(to: f.server)
            #expect(
                try client.captures().first?.generated.taggingInputFingerprint
                    == complete.taggingInputFingerprint)
            #expect(try client.captures().first?.generated.taggingProcessed == true)
        }
        try client.enqueue(
            captureID: capture.id,
            mutation: .edit(
                CaptureEdit(generated: GeneratedContent(body: "Legacy replacement", tags: []))))
        try client.push(to: f.server)
        #expect(try client.captures().first?.generated.body == "Legacy replacement")
        #expect(try client.captures().first?.generated.taggingProcessed == true)
        #expect(
            try client.captures().first?.generated.taggingInputFingerprint
                == complete.taggingInputFingerprint)
    }

    @Test func newMarkerWritesRejectMissingEmptyOversizedAndInconsistentFingerprints() throws {
        let f = try ProcessingFixture()
        defer { f.clean() }
        let client = try f.client("validation")
        let invalid = [
            GeneratedContent(taggingProcessed: true),
            GeneratedContent(taggingProcessed: true, taggingInputFingerprint: ""),
            GeneratedContent(
                taggingProcessed: true, taggingInputFingerprint: String(repeating: "x", count: 257)),
            GeneratedContent(
                taggingProcessed: true, taggingInputFingerprint: String(repeating: "é", count: 129)),
            GeneratedContent(taggingProcessed: false, taggingInputFingerprint: "stale"),
            GeneratedContent(taggingInputFingerprint: "missing-state"),
        ]
        for generated in invalid {
            var capture = f.capture()
            capture.generated = generated
            #expect(throws: SyncError.invalidOperation) {
                try client.enqueue(captureID: capture.id, mutation: .create(capture))
            }
            #expect(throws: SyncError.invalidOperation) {
                try client.enqueue(
                    captureID: capture.id, mutation: .edit(CaptureEdit(generated: generated)))
            }
        }
        for fingerprint in ["", String(repeating: "é", count: 129)] {
            #expect(throws: SyncError.invalidOperation) {
                try client.enqueue(
                    captureID: UUID(),
                    mutation: .edit(
                        CaptureEdit(
                            generatedPatch: GeneratedContentPatch(
                                taggingProcessing: .processed(inputFingerprint: fingerprint)))))
            }
        }
        #expect(try client.pendingOperations().isEmpty)
        let capture = f.capture()
        let first = try client.enqueue(captureID: capture.id, mutation: .create(capture))
        #expect(first.sequence == 1)
        let fingerprint = String(repeating: "é", count: 128)
        try client.enqueue(
            captureID: capture.id,
            mutation: .edit(
                CaptureEdit(
                    generatedPatch: GeneratedContentPatch(
                        taggingProcessing: .processed(inputFingerprint: fingerprint)))))
        try client.push(to: f.server)
        #expect(try client.captures().first?.generated.taggingInputFingerprint == fingerprint)
        #expect(throws: DecodingError.self) {
            try SyncDatabase.decode(
                GeneratedContentPatch.self,
                Data(#"{"taggingProcessing":{"futureState":{}}}"#.utf8))
        }
    }

    @Test func oldPayloadBytesAndLegacyDescriptiveMarkersRemainReadableAndPreserved() throws {
        let f = try ProcessingFixture()
        defer { f.clean() }
        let old = Data(#"{"body":"Original","tags":[]}"#.utf8)
        let decoded = try SyncDatabase.decode(GeneratedContent.self, old)
        #expect(decoded.taggingProcessed == nil)
        #expect(decoded.taggingInputFingerprint == nil)
        #expect(try SyncDatabase.encode(decoded) == old)
        let legacy = Data(#"{"taggingProcessed":true,"tags":[]}"#.utf8)
        let descriptive = try SyncDatabase.decode(GeneratedContent.self, legacy)
        #expect(descriptive.taggingProcessed == true)
        #expect(descriptive.taggingInputFingerprint == nil)
        #expect(try SyncDatabase.encode(descriptive) == legacy)
        var capture = f.capture()
        capture.generated = descriptive
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let authority = try SyncServer(
            databaseURL: f.root.appendingPathComponent("bound.sqlite"),
            blobDirectory: f.root.appendingPathComponent("bound-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        let snapshot = ContentSnapshotImport(
            snapshotID: UUID(), targetBinding: binding, sourceDeviceID: UUID(), captures: [capture])
        try authority.importContentSnapshot(
            snapshot, preview: authority.previewContentSnapshotImport(snapshot))
        #expect(try authority.baseline().captures.first?.generated == descriptive)
        #expect(
            try authority.retainedContentSnapshotImport(snapshot.snapshotID)?.snapshot == snapshot)
    }
}

private struct ProcessingFixture {
    let root: URL
    let server: SyncServer
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-processing-\(UUID())")
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-blobs"))
    }
    func client(_ name: String) throws -> SyncClient {
        try SyncClient(
            databaseURL: root.appendingPathComponent("\(name).sqlite"),
            blobDirectory: root.appendingPathComponent("\(name)-blobs"))
    }
    func capture() -> SharedCapture {
        SharedCapture(source: CaptureSource(kind: .text, selection: "Synthetic processing capture"))
    }
    func outbox(_ name: String) throws -> [Data] {
        let db = try DatabaseQueue(path: root.appendingPathComponent("\(name).sqlite").path)
        return try db.read {
            try Data.fetchAll($0, sql: "SELECT payload FROM sync_outbox ORDER BY sequence")
        }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
