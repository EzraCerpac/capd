import CapdSync
import Foundation
import Testing

@testable import CapdMobile

struct LegacyWebsiteIconTests {
    @Test func cacheNeedsDurableOwnershipAndALiveLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try MobileLibrarySession.open(root: root, role: .shareExtension)
        let url = "https://sqlite.org/first"
        let marker = root.appendingPathComponent("Library/legacy-website-icons-library.json")
        let directory = root.appendingPathComponent(
            "Library/Caches/WebsiteIcons", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try session.store.save(CaptureInput.make(text: url, isLink: true))
        #expect(try session.legacyWebsiteIconDirectory(for: url, token: session.token) == nil)
        let owner = try JSONEncoder().encode(session.configuration)
        try owner.write(to: marker)
        #expect(try session.legacyWebsiteIconDirectory(for: url, token: session.token) == directory)
        #expect(
            try session.legacyWebsiteIconDirectory(
                for: "https://www.sqlite.org", token: session.token) == nil)
        #expect(
            try session.legacyWebsiteIconDirectory(for: "http://sqlite.org", token: session.token)
                == nil)
        let reopened = try MobileLibrarySession.open(root: root, role: .shareExtension)
        #expect(
            try reopened.legacyWebsiteIconDirectory(for: url, token: reopened.token) == directory)
        #expect(try Data(contentsOf: marker) == owner)
        try Data("{}".utf8).write(to: marker)
        #expect(try reopened.legacyWebsiteIconDirectory(for: url, token: reopened.token) == nil)
        try FileManager.default.removeItem(at: marker)
        #expect(try reopened.legacyWebsiteIconDirectory(for: url, token: reopened.token) == nil)
    }

    @Test func aNewLibraryCannotAdoptTheOldGlobalCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try MobileLibrarySession.open(root: root, role: .shareExtension)
        let url = "https://sqlite.org/first"
        let marker = root.appendingPathComponent("Library/legacy-website-icons-library.json")
        let owner = try JSONEncoder().encode(first.configuration)
        try owner.write(to: marker)
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.org/v1/sync")!,
            binding: binding, deviceID: UUID())
        let next = MobileLibraryConfiguration(generation: UUID(), enrollment: enrollment)
        try MobileLibraryAccess.publish(next, in: root)
        #expect(throws: MobileActivationError.sessionReplaced) {
            try first.legacyWebsiteIconDirectory(for: url, token: first.token)
        }
        let second = try MobileLibrarySession.open(root: root, role: .shareExtension)
        try second.store.save(CaptureInput.make(text: url, isLink: true))
        #expect(try second.legacyWebsiteIconDirectory(for: url, token: second.token) == nil)
        let restarted = try MobileLibrarySession.open(root: root, role: .shareExtension)
        #expect(try restarted.legacyWebsiteIconDirectory(for: url, token: restarted.token) == nil)
        #expect(try Data(contentsOf: marker) == owner)
    }

    @Test(arguments: ["marker", "directory"])
    func symlinksDoNotRedirectOwnershipOrPixels(target: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try MobileLibrarySession.open(root: root, role: .shareExtension)
        let url = "https://sqlite.org/first"
        try session.store.save(CaptureInput.make(text: url, isLink: true))
        let marker = root.appendingPathComponent("Library/legacy-website-icons-library.json")
        try JSONEncoder().encode(session.configuration).write(to: marker)
        if target == "marker" {
            let other = root.appendingPathComponent("owner.json")
            try FileManager.default.moveItem(at: marker, to: other)
            try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: other)
        } else {
            let other = root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let caches = root.appendingPathComponent("Library/Caches", isDirectory: true)
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: caches.appendingPathComponent("WebsiteIcons"), withDestinationURL: other)
        }
        #expect(try session.legacyWebsiteIconDirectory(for: url, token: session.token) == nil)
    }

    @Test func aPendingTombstoneIsAuthorityEvenBeforeItsReceipt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        let enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.org/v1/sync")!, binding: binding,
            deviceID: UUID())
        let configuration = MobileLibraryConfiguration(generation: UUID(), enrollment: enrollment)
        try MobileLibraryAccess.publish(configuration, in: root)
        let session = try MobileLibrarySession.open(root: root, role: .shareExtension)
        let url = "https://sqlite.org/first"
        try session.store.save(CaptureInput.make(text: url, isLink: true))
        let marker = root.appendingPathComponent("Library/legacy-website-icons-library.json")
        try JSONEncoder().encode(configuration).write(to: marker)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Library/Caches/WebsiteIcons"),
            withIntermediateDirectories: true)
        #expect(try session.legacyWebsiteIconDirectory(for: url, token: session.token) != nil)
        let database = try configuration.databaseURL(in: root)
        let client = try SyncClient(
            databaseURL: database,
            blobDirectory: database.deletingLastPathComponent().appendingPathComponent("assets"),
            deviceID: enrollment.deviceID, binding: binding)
        try client.enqueueWebsiteIcon(
            origin: #require(WebsiteIconOrigin(url: url)), mutation: .tombstone)
        #expect(try session.websiteIcon(for: url, token: session.token) == nil)
        #expect(try session.websiteIconRecord(for: url, token: session.token)?.deleted == true)
        #expect(try session.legacyWebsiteIconDirectory(for: url, token: session.token) == nil)
    }
}
