import Foundation
import Testing

@testable import CapdSync

@Suite("Shared extraction quality")
struct ExtractionQualityTests {
    @Test func classificationRoundTripsAndTracksBodyReplacements() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-quality-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("blobs"))
        let client = try SyncClient(
            databaseURL: root.appendingPathComponent("client.sqlite"),
            blobDirectory: root.appendingPathComponent("client-blobs"))
        var capture = SharedCapture(
            source: CaptureSource(kind: .link, url: "https://example.invalid"))
        capture.generated = GeneratedContent(body: "Login wall", bodyIsThin: true)
        #expect(
            try JSONDecoder().decode(
                GeneratedContent.self, from: JSONEncoder().encode(capture.generated))
                == capture.generated)
        let legacy = try JSONDecoder().decode(
            GeneratedContent.self, from: Data(#"{"body":"Legacy body","tags":[]}"#.utf8))
        #expect(legacy.bodyIsThin == nil)
        try client.enqueue(captureID: capture.id, mutation: .create(capture))
        try client.push(to: server)
        #expect(try server.baseline().captures.first?.generated.bodyIsThin == true)
        let patches: [(GeneratedContentPatch, String?, Bool?)] = [
            (GeneratedContentPatch(tags: ["tag"]), "Login wall", true),
            (GeneratedContentPatch(bodyIsThin: false), "Login wall", false),
            (GeneratedContentPatch(body: .set("Paywall"), bodyIsThin: true), "Paywall", true),
            (GeneratedContentPatch(body: .set("Usable replacement")), "Usable replacement", nil),
            (GeneratedContentPatch(body: .set("")), "", nil),
            (GeneratedContentPatch(body: .clear), nil, nil),
        ]
        for (patch, body, isThin) in patches {
            #expect(
                try JSONDecoder().decode(
                    GeneratedContentPatch.self, from: JSONEncoder().encode(patch)) == patch)
            try client.enqueue(
                captureID: capture.id, mutation: .edit(CaptureEdit(generatedPatch: patch)))
            #expect(try client.captures().first?.generated.bodyIsThin == isThin)
            try client.push(to: server)
            let generated = try #require(try server.baseline().captures.first?.generated)
            #expect(generated.body == body)
            #expect(generated.bodyIsThin == isThin)
        }
        #expect(throws: SyncError.invalidOperation) {
            try client.enqueue(
                captureID: capture.id,
                mutation: .edit(
                    CaptureEdit(generatedPatch: GeneratedContentPatch(bodyIsThin: true))))
        }
        #expect(try client.pendingOperations().isEmpty)
        try client.enqueue(
            captureID: capture.id,
            mutation: .edit(
                CaptureEdit(generated: GeneratedContent(body: "Legacy thin", bodyIsThin: true))))
        try client.enqueue(
            captureID: capture.id,
            mutation: .edit(
                CaptureEdit(generated: GeneratedContent(body: "Legacy thin", tags: ["tag"]))))
        #expect(try client.captures().first?.generated.bodyIsThin == true)
        try client.enqueue(
            captureID: capture.id,
            mutation: .edit(CaptureEdit(generated: GeneratedContent(body: "Legacy healthy"))))
        #expect(try client.captures().first?.generated.bodyIsThin == nil)
        try client.push(to: server)
        #expect(try server.baseline().captures.first?.generated.bodyIsThin == nil)
        var invalid = SharedCapture(source: CaptureSource(kind: .link))
        invalid.generated = GeneratedContent(bodyIsThin: true)
        #expect(throws: SyncError.invalidOperation) {
            try client.enqueue(captureID: invalid.id, mutation: .create(invalid))
        }
    }
}
