import CapdMobile
import CapdSync
import CoreGraphics
import Foundation
import ImageIO
import Network
import Testing
import UniformTypeIdentifiers

@testable import CapdKit
@testable import CapdSync

@Suite("Website icon authenticated HTTP integration")
struct WebsiteIconHTTPIntegrationTests {
    @Test func phoneOriginIsGeneratedOnceAndReturnsAcrossLostAcknowledgement() async throws {
        let fixture = try await IconHTTPFixture()
        defer { fixture.clean() }

        let macStore = try fixture.openMacStore()
        let macClient = try #require(macStore.syncClient)
        let macTransport = try fixture.transport(device: fixture.macDevice)
        let phone = try fixture.openPhoneStore()
        let phoneTransport = try fixture.transport(device: fixture.phoneDevice)
        let first = MobileCapture(
            kind: .link, url: "https://example.org/first", title: "Wombat first page",
            selection: "Wombat saved passage one")
        let second = MobileCapture(
            kind: .link, url: "https://example.org/second", title: "Wombat second page",
            selection: "Wombat saved passage two")
        _ = try phone.save(first)
        _ = try phone.save(second)
        _ = try await phone.push(to: phoneTransport, credential: { fixture.phoneToken })
        try await pullCaptures(macClient, from: macTransport, credential: fixture.macToken)
        #expect(try macClient.captures().count == 2)

        try macStore.setWebsiteIconsEnabled(true)
        let bytes = try iconPNG(red: 0.18, green: 0.47, blue: 0.77)
        let generator = IconGenerator(bytes: bytes)
        let service = WebsiteIconService(store: macStore) { origin in
            await generator.fetch(origin)
        }
        #expect(try await service.processNext())
        #expect(try await !service.processNext())
        #expect(await generator.origins == ["https://example.org"])

        let localRecord = try #require(try macStore.websiteIcon(for: "https://example.org/other"))
        let pendingBeforeRestart = try macClient.pendingWebsiteIconOperations()
        #expect(pendingBeforeRestart.count == 1)
        let reopenedMac = try fixture.openMacStore()
        let reopenedMacClient = try #require(reopenedMac.syncClient)
        #expect(try reopenedMacClient.pendingWebsiteIconOperations() == pendingBeforeRestart)
        #expect(try reopenedMac.verifiedWebsiteIconData(localRecord) == bytes)

        fixture.host.dropNextWebsiteIconApplyResponse = true
        await #expect(throws: SyncError.transportDisconnected) {
            try await reopenedMacClient.pushWebsiteIcons(
                to: macTransport, credential: { fixture.macToken })
        }
        #expect(try reopenedMacClient.pendingWebsiteIconOperations() == pendingBeforeRestart)
        let firstApply = try #require(fixture.host.websiteIconApplyBodies.first)
        #expect(try fixture.server.websiteIconBaseline().records.count == 1)

        try await reopenedMacClient.pushWebsiteIcons(
            to: macTransport, credential: { fixture.macToken })
        #expect(try reopenedMacClient.pendingWebsiteIconOperations().isEmpty)
        #expect(fixture.host.websiteIconApplyBodies.count == 2)
        #expect(fixture.host.websiteIconApplyBodies[1] == firstApply)
        #expect(try fixture.server.websiteIconBaseline().records.count == 1)

        let mobileRevisionBeforeIcons = try phone.libraryRevision()
        let searchBeforeIcons = try phone.search("wombat")
        let answerReader = try MobileAnswerRetrieval(databaseURL: fixture.phoneDatabase)
        let evidenceRevisionBeforeIcons = try await answerReader.evidenceRevision()
        let evidenceBeforeIcons = try await answerReader.search("wombat", limit: 5)
        #expect(!evidenceBeforeIcons.isEmpty)

        try await phone.pullWebsiteIcons(
            from: phoneTransport, credential: { fixture.phoneToken })
        let phoneRecord = try #require(try phone.websiteIcon(for: "https://example.org/first"))
        #expect(try phone.websiteIconData(phoneRecord) == bytes)
        #expect(try phone.libraryRevision() == mobileRevisionBeforeIcons)
        #expect(try phone.search("wombat") == searchBeforeIcons)
        #expect(try await answerReader.evidenceRevision() == evidenceRevisionBeforeIcons)
        #expect(try await answerReader.search("wombat", limit: 5) == evidenceBeforeIcons)

        let offlineReopen = try fixture.openPhoneStore()
        let reopenedRecord = try #require(
            try offlineReopen.websiteIcon(for: "https://example.org/second"))
        #expect(try offlineReopen.websiteIconData(reopenedRecord) == bytes)
        #expect(try offlineReopen.libraryRevision() == mobileRevisionBeforeIcons)
        #expect(try offlineReopen.search("wombat") == searchBeforeIcons)

        _ = try phone.delete(id: first.id)
        _ = try await phone.push(to: phoneTransport, credential: { fixture.phoneToken })
        let stillShared = try #require(try fixture.server.websiteIconBaseline().records.first)
        #expect(!stillShared.deleted)
        #expect(try phone.websiteIcon(for: "https://example.org") != nil)

        _ = try phone.delete(id: second.id)
        _ = try await phone.push(to: phoneTransport, credential: { fixture.phoneToken })
        let tombstone = try #require(try fixture.server.websiteIconBaseline().records.first)
        #expect(tombstone.deleted)
        try await phone.pullWebsiteIcons(
            from: phoneTransport, credential: { fixture.phoneToken })
        #expect(try phone.websiteIcon(for: "https://example.org") == nil)

        try await pullCaptures(macClient, from: macTransport, credential: fixture.macToken)
        try await macClient.pullWebsiteIcons(from: macTransport, credential: { fixture.macToken })
        try macStore.refreshWebsiteIconsFromSync()
        let deletedCapture = try #require(
            try macClient.captures(includeDeleted: true).first { $0.id == first.id })
        #expect(deletedCapture.deleted)
        _ = try macClient.enqueue(captureID: deletedCapture.id, mutation: .restore)
        _ = try await macClient.push(to: macTransport, credential: { fixture.macToken })
        try await phone.pull(from: phoneTransport, credential: { fixture.phoneToken })

        let restoredBytes = try iconPNG(red: 0.77, green: 0.36, blue: 0.12)
        let restoreGenerator = IconGenerator(bytes: restoredBytes)
        let restoreService = WebsiteIconService(store: macStore) { origin in
            await restoreGenerator.fetch(origin)
        }
        #expect(try await restoreService.processNext())
        #expect(await restoreGenerator.origins == ["https://example.org"])
        try await macClient.pushWebsiteIcons(to: macTransport, credential: { fixture.macToken })
        try await phone.pullWebsiteIcons(
            from: phoneTransport, credential: { fixture.phoneToken })
        let restoredIcon = try #require(try phone.websiteIcon(for: "https://example.org"))
        #expect(try phone.websiteIconData(restoredIcon) == restoredBytes)
        #expect(try fixture.server.websiteIconBaseline().records.first?.deleted == false)
    }

    @Test func macOriginAlsoFlowsThroughServerToPhone() async throws {
        let fixture = try await IconHTTPFixture()
        defer { fixture.clean() }

        let macStore = try fixture.openMacStore()
        let client = try #require(macStore.syncClient)
        let macTransport = try fixture.transport(device: fixture.macDevice)
        let phoneTransport = try fixture.transport(device: fixture.phoneDevice)
        let phone = try fixture.openPhoneStore()
        let capture = try CaptureService(store: macStore).ingest(
            CaptureRequest(url: "https://mac-origin.org/article", fetchBody: false)
        ).capture
        _ = try await client.push(to: macTransport, credential: { fixture.macToken })
        try await phone.pull(from: phoneTransport, credential: { fixture.phoneToken })
        let sharedID = try #require(client.captures().first?.id)
        #expect(try phone.capture(id: sharedID) != nil)
        #expect(capture.id != nil)

        try macStore.setWebsiteIconsEnabled(true)
        let bytes = try iconPNG(red: 0.58, green: 0.22, blue: 0.68)
        let generator = IconGenerator(bytes: bytes)
        let service = WebsiteIconService(store: macStore) { origin in
            await generator.fetch(origin)
        }
        #expect(try await service.processNext())
        try await client.pushWebsiteIcons(to: macTransport, credential: { fixture.macToken })
        try await phone.pullWebsiteIcons(
            from: phoneTransport, credential: { fixture.phoneToken })
        let record = try #require(try phone.websiteIcon(for: "https://mac-origin.org"))
        #expect(try phone.websiteIconData(record) == bytes)
    }
}

private func pullCaptures(
    _ client: SyncClient, from transport: URLSessionSyncTransport,
    credential: String
) async throws {
    for _ in 0..<8 {
        let before = try client.cursor()
        try await client.pull(from: transport, credential: { credential })
        if try client.cursor() == before { return }
    }
    Issue.record("Capture pull did not settle within its bounded integration loop")
}

private func iconPNG(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let encoded = data as Data
    var stripped = Data(encoded.prefix(8))
    var offset = 8
    while offset + 12 <= encoded.count {
        let size = encoded[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
        let end = offset + 12 + size
        let type = String(decoding: encoded[(offset + 4)..<(offset + 8)], as: UTF8.self)
        guard end <= encoded.count else { throw CocoaError(.fileReadCorruptFile) }
        if ["IHDR", "IDAT", "IEND"].contains(type) { stripped.append(encoded[offset..<end]) }
        offset = end
    }
    return stripped
}

private actor IconGenerator {
    private let bytes: Data
    private(set) var origins: [String] = []

    init(bytes: Data) { self.bytes = bytes }

    func fetch(_ origin: WebsiteIconOrigin) -> WebsiteIconFetchOutcome {
        origins.append(origin.canonicalHTTPSOrigin)
        return .normalizedPNG(bytes)
    }
}

private struct IconHTTPFixture {
    let root: URL
    let binding: SyncLibraryBinding
    let macDevice: UUID
    let phoneDevice: UUID
    let macToken: String
    let phoneToken: String
    let macPaths: StoragePaths
    let phoneRoot: URL
    let phoneDatabase: URL
    let server: SyncServer
    let host: InProcessIconHTTPHost

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capd-icon-http-integration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
        macDevice = UUID()
        phoneDevice = UUID()
        macToken = UUID().uuidString + UUID().uuidString
        phoneToken = UUID().uuidString + UUID().uuidString
        macPaths = StoragePaths(root: root.appendingPathComponent("mac"))
        phoneRoot = root.appendingPathComponent("phone")
        phoneDatabase = phoneRoot.appendingPathComponent("capd.sqlite")
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-blobs"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        let authorizer = IconHTTPAuthorizer(
            principals: [
                macToken: SyncPrincipal(
                    serviceID: binding.serviceID, libraryID: binding.libraryID,
                    deviceID: macDevice),
                phoneToken: SyncPrincipal(
                    serviceID: binding.serviceID, libraryID: binding.libraryID,
                    deviceID: phoneDevice),
            ])
        let serviceID = binding.serviceID
        let authority = server
        let handler = SyncHTTPHandler(
            serviceID: serviceID, authorizer: authorizer
        ) { _ in
            return authority
        }
        host = try await InProcessIconHTTPHost.start(handler: handler)
        try FileManager.default.createDirectory(
            at: macPaths.root, withIntermediateDirectories: true)
        let enrollment = try SyncEnrollment(
            endpoint: URL(string: "https://sync.example.invalid/v1/sync")!, binding: binding,
            deviceID: macDevice)
        try MacSyncConfiguration(enrollment: enrollment).install(paths: macPaths)
    }

    func transport(device: UUID) throws -> URLSessionSyncTransport {
        try URLSessionSyncTransport(
            endpoint: host.endpoint, binding: binding, deviceID: device,
            policy: .syntheticLoopback, timeout: 10)
    }

    func openMacStore() throws -> Store {
        try Store(paths: macPaths, syncBinding: binding, deviceID: macDevice)
    }

    func openPhoneStore() throws -> MobileStore {
        try MobileStore(url: phoneDatabase, deviceID: phoneDevice, binding: binding)
    }

    func clean() {
        host.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

private struct IconHTTPAuthorizer: SyncAuthorizer {
    let principals: [String: SyncPrincipal]

    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        principals[bearerCredential]
    }
}

private final class InProcessIconHTTPHost: @unchecked Sendable {
    private let lock = NSLock()
    private let listener: NWListener
    private let handler: SyncHTTPHandler
    private let queue = DispatchQueue(label: "capd.website-icon-http.\(UUID())")
    private var connections: [NWConnection] = []
    private var shouldDropIconApplyResponse = false
    private var iconApplyBodies: [Data] = []

    var endpoint: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/v1/sync")!
    }

    var dropNextWebsiteIconApplyResponse: Bool {
        get { lock.withLock { shouldDropIconApplyResponse } }
        set { lock.withLock { shouldDropIconApplyResponse = newValue } }
    }

    var websiteIconApplyBodies: [Data] { lock.withLock { iconApplyBodies } }

    private init(handler: SyncHTTPHandler) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(handler: SyncHTTPHandler) async throws -> InProcessIconHTTPHost {
        let host = try InProcessIconHTTPHost(handler: handler)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            host.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    host.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    host.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            host.listener.newConnectionHandler = { connection in
                host.lock.withLock { host.connections.append(connection) }
                connection.start(queue: host.queue)
                host.receive(connection, buffer: Data())
            }
            host.listener.start(queue: host.queue)
        }
        return host
    }

    func stop() {
        listener.cancel()
        lock.withLock {
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil,
                buffer.count <= SyncHTTPHandler.maximumBodyBytes + 16_384
            else {
                connection.cancel()
                return
            }
            if let separator = buffer.range(of: Data("\r\n\r\n".utf8)),
                let headerText = String(data: buffer[..<separator.lowerBound], encoding: .utf8)
            {
                let lines = headerText.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pieces = line.split(separator: ":", maxSplits: 1)
                    if pieces.count == 2 {
                        headers[String(pieces[0])] = pieces[1].trimmingCharacters(
                            in: .whitespaces)
                    }
                }
                let count =
                    headers.first(where: { $0.key.lowercased() == "content-length" })
                    .flatMap { Int($0.value) } ?? 0
                if count >= 0, buffer.count - separator.upperBound >= count {
                    let requestLine = lines.first?.split(separator: " ") ?? []
                    let method = requestLine.first.map(String.init) ?? ""
                    let path = requestLine.dropFirst().first.map(String.init) ?? ""
                    let request = SyncHTTPRequest(
                        method: method, path: path, headers: headers,
                        body: buffer.subdata(
                            in: separator.upperBound..<(separator.upperBound + count)))
                    self.respond(connection, request: request)
                    return
                }
            }
            if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
        }
    }

    private func respond(_ connection: NWConnection, request: SyncHTTPRequest) {
        let envelope = try? JSONDecoder().decode(SyncHTTPEnvelope.self, from: request.body)
        let isWebsiteIconApply: Bool
        if case .applyWebsiteIcon = envelope?.action {
            isWebsiteIconApply = true
        } else {
            isWebsiteIconApply = false
        }
        let response = handler.handle(request)
        let shouldDrop = lock.withLock { () -> Bool in
            guard isWebsiteIconApply else { return false }
            iconApplyBodies.append(request.body)
            let drop = shouldDropIconApplyResponse
            shouldDropIconApplyResponse = false
            return drop
        }
        if shouldDrop {
            connection.cancel()
            return
        }
        var head =
            "HTTP/1.1 \(response.status) Response\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        let bytes = Data((head + "\r\n").utf8) + response.body
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}
