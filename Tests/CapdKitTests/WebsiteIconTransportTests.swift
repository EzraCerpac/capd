import CapdSync
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Security
import Testing
import UniformTypeIdentifiers

@testable import CapdKit

@Suite(.serialized)
struct WebsiteIconTransportTests {
    @Test func publicBinaryAddressesAndMappedRefusals() throws {
        for text in ["8.8.8.8", "93.184.216.34", "2606:4700:4700::1111"] {
            let address = try #require(WebsiteIconAddress(numeric: text))
            #expect(WebsiteIconAddressPolicy.isPublic(address))
            address.withSocketAddress { pointer, _ in
                #expect(WebsiteIconAddress(socketAddress: pointer) == address)
            }
        }
        for text in [
            "0.1.2.3", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.0.1",
            "192.168.1.1", "192.0.2.1", "198.18.0.1", "224.0.0.1", "::1", "fc00::1", "fe80::1",
            "::ffff:8.8.8.8", "2001:db8::1", "2002:808:808::1", "3ffe::1", "3fff::1",
        ] {
            #expect(
                !WebsiteIconAddressPolicy.isPublic(try #require(WebsiteIconAddress(numeric: text))))
        }
        #expect(WebsiteIconAddress(numeric: "8.8.8.8.example.com") == nil)
        #expect(WebsiteIconAddress(numeric: "127.1") == nil)
        #expect(throws: WebsiteIconTransportError.refusedAddress) {
            try WebsiteIconSocket.connect(
                WebsiteIconAddress(numeric: "127.0.0.1")!, deadline: .now.advanced(by: .seconds(1)),
                cancellation: WebsiteIconCancellation())
        }
    }

    @Test func incrementalFixedAndChunkedFraming() throws {
        for message in [
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n",
        ] {
            var parser = WebsiteIconHTTPParser()
            for byte in message.utf8 { try parser.append(Data([byte])) }
            #expect(try parser.end().body == Data("hello".utf8))
        }
        var count = WebsiteIconHTTPParser.bodyLimit
        var header = ""
        while true {
            header = "HTTP/1.1 200 OK\r\nContent-Length: \(count)\r\n\r\n"
            let next = WebsiteIconHTTPParser.bodyLimit - header.utf8.count
            if next == count { break }
            count = next
        }
        var parser = WebsiteIconHTTPParser()
        try parser.append(Data(header.utf8))
        var remaining = count
        while remaining > 0 {
            let size = min(8192, remaining)
            try parser.append(Data(repeating: 65, count: size))
            remaining -= size
        }
        #expect(try parser.end().body.count == count)

    }

    @Test(arguments: [false, true])
    func repeatedUnrelatedHeadersAreIgnored(chunked: Bool) throws {
        let headers = [
            "Set-Cookie", "X-Trace-2", "9-Trace", "X.!#$%&'*+^_`|~", "Content-Language",
            "Content-Type", "Content-Range",
            "Content-Disposition", "Connection", "Trailer", "Upgrade", "Location",
            "WWW-Authenticate", "Proxy-Authenticate", "Authentication-Info",
            "Proxy-Authentication-Info", "Authorization", "Proxy-Authorization",
            "Strict-Transport-Security",
        ].map { "\($0): first\r\n\($0.lowercased()): second\r\n" }.joined()
        let framing = chunked ? "Transfer-Encoding: chunked" : "Content-Length: 5"
        let body = chunked ? "5\r\nhello\r\n0\r\n\r\n" : "hello"
        let message = "HTTP/1.1 200 OK\r\n\(headers)\(framing)\r\n\r\n\(body)"
        var parser = WebsiteIconHTTPParser()
        for byte in message.utf8 { try parser.append(Data([byte])) }
        #expect(try parser.end() == WebsiteIconHTTPResponse(status: 200, body: Data("hello".utf8)))
    }

    @Test(arguments: ["X-Trace-2", "9-Trace", "X.!#$%&'*+^_`|~"])
    func validIgnoredFieldNamesAreAccepted(_ name: String) throws {
        var parser = WebsiteIconHTTPParser()
        try parser.append(
            Data("HTTP/1.1 200 OK\r\n\(name): ignored\r\nContent-Length: 1\r\n\r\nx".utf8))
        #expect(try parser.end().body == Data("x".utf8))
    }

    @Test(arguments: ["Content-Length", "Transfer-Encoding", "Content-Encoding"])
    func consumedDuplicateHeadersStillRefused(_ name: String) throws {
        let chunked = name == "Transfer-Encoding"
        let value = name == "Content-Length" ? "1" : chunked ? "chunked" : "identity"
        let framing = name == "Content-Length" || chunked ? "" : "Content-Length: 1\r\n"
        let body = chunked ? "1\r\nx\r\n0\r\n\r\n" : "x"
        let header = "HTTP/1.1 200 OK\r\n\(name): \(value)\r\n"
        var accepted = WebsiteIconHTTPParser()
        try accepted.append(Data("\(header)\(framing)\r\n\(body)".utf8))
        #expect(try accepted.end().body == Data("x".utf8))
        #expect(throws: WebsiteIconTransportError.invalidHTTP) {
            var parser = WebsiteIconHTTPParser()
            try parser.append(
                Data("\(header)\(name.lowercased()): \(value)\r\n\(framing)\r\n\(body)".utf8))
        }
    }

    @Test func ignoredHeadersStillObeyGrammarAndBudgets() {
        for headers in [
            "Set-Cookie: first=ok\r\nSet-Cookie: bad\u{1}", "X-Trace: first\r\n X-Trace: second",
            "X-Trace: first\r\n\tX-Trace: second", "Bad Name: ignored", "Bad\tName: ignored",
            "(Bad): ignored", "Bad\u{1}Name: ignored", ": ignored",
        ] {
            #expect(throws: WebsiteIconTransportError.invalidHTTP) {
                var parser = WebsiteIconHTTPParser()
                try parser.append(
                    Data("HTTP/1.1 200 OK\r\n\(headers)\r\nContent-Length: 1\r\n\r\nx".utf8))
            }
        }
        #expect(throws: (any Error).self) {
            var parser = WebsiteIconHTTPParser()
            let headers = String(repeating: "Set-Cookie: ignored=value\r\n", count: 800)
            try parser.append(Data("HTTP/1.1 200 OK\r\n\(headers)Content-Length: 1\r\n\r\nx".utf8))
        }
    }

    @Test(arguments: [
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: identity\r\n\r\n1\r\nx\r\n0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 1\r\n\r\nx",
        "HTTP/1.1 200 OK\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nx",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nxy",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;ext=x\r\nx\r\n0\r\n\r\n",
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\nTrailer: x\r\n\r\n",
        "HTTP/1.1 200 OK\r\n Content-Length: 1\r\n\r\nx",
    ])
    func ambiguousFramingRefused(_ message: String) {
        #expect(throws: WebsiteIconTransportError.invalidHTTP) {
            var parser = WebsiteIconHTTPParser()
            try parser.append(Data(message.utf8))
            _ = try parser.end()
        }
    }

    @Test func streamAndHeaderLimitsAndStatus() {
        #expect(throws: WebsiteIconTransportError.tooLarge) {
            var parser = WebsiteIconHTTPParser()
            try parser.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 262145\r\n\r\n".utf8))
        }
        #expect(throws: WebsiteIconTransportError.tooLarge) {
            var parser = WebsiteIconHTTPParser()
            try parser.append(Data(repeating: 65, count: 16385))
        }
        for status in [301, 302, 401, 403, 404, 410] {
            #expect(throws: WebsiteIconTransportError.status(status)) {
                var parser = WebsiteIconHTTPParser()
                try parser.append(Data("HTTP/1.1 \(status) Refused\r\n\r\n".utf8))
            }
        }
        #expect(throws: (any Error).self) {
            var parser = WebsiteIconHTTPParser()
            try parser.append(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
            for _ in 0..<4000 { try parser.append(Data("1\r\nx\r\n".utf8)) }
        }
    }

    @Test func imagesBecomeOnlyStaticPixelChunks() throws {
        for type in [UTType.png, UTType.jpeg] {
            let source = try Self.image(type: type)
            #expect(source.range(of: Data("secret synthetic metadata".utf8)) != nil)
            let normalized = try #require(WebsiteIconImage.normalizedPNG(source))
            let chunks = try Self.chunks(normalized)
            #expect(chunks.map(\.0) == ["IHDR", "IDAT", "IEND"])
            let header = chunks[0].1
            #expect(Array(header.prefix(8)) == [0, 0, 0, 64, 0, 0, 0, 64])
            #expect(header[8] == 8 && [2, 6].contains(header[9]) && header[12] == 0)
            let decoded = try #require(CGImageSourceCreateWithData(normalized as CFData, nil))
            #expect(CGImageSourceGetCount(decoded) == 1)
        }
        let png = try Self.image(type: .png)
        var corrupt = png
        corrupt[29] ^= 1
        #expect(WebsiteIconImage.normalizedPNG(corrupt) == nil)
        var ico = Data([0, 0, 1, 0, 1, 0, 32, 16, 0, 0, 1, 0, 32, 0])
        var length = UInt32(png.count).littleEndian
        var offset: UInt32 = 22
        withUnsafeBytes(of: &length) { ico.append(contentsOf: $0) }
        withUnsafeBytes(of: &offset) { ico.append(contentsOf: $0) }
        ico.append(png)
        #expect(WebsiteIconImage.normalizedPNG(ico) != nil)
        #expect(WebsiteIconImage.normalizedPNG(try Self.image(type: .gif)) == nil)
        #expect(WebsiteIconImage.normalizedPNG(Data("<svg/>".utf8)) == nil)
        #expect(WebsiteIconImage.normalizedPNG(Data(png.dropLast(12))) == nil)
        #expect(WebsiteIconImage.normalizedPNG(Data(repeating: 0, count: 262145)) == nil)
        #expect(
            WebsiteIconImage.normalizedPNG(try Self.image(type: .png, width: 4097, height: 1))
                == nil)
    }

    @Test func dnsBatchValidationCancellationAndDeadlineCloseExactlyOnce() async throws {
        let publicAddress = WebsiteIconAddress(numeric: "8.8.8.8")!
        let probe = DNSProbe()
        let resolver = WebsiteIconDNSResolver(start: probe.start)
        let task = Task {
            try await resolver.resolve("www.example.com", deadline: .now.advanced(by: .seconds(2)))
        }
        try await probe.waitStarted()
        probe.deliver(.success(.init(address: publicAddress, added: true, moreComing: true)))
        probe.deliver(.success(.init(address: publicAddress, added: true, moreComing: false)))
        #expect(try await task.value == [publicAddress])
        #expect(probe.stops == 1)
        probe.deliver(.failure(WebsiteIconTransportError.dns))
        #expect(probe.stops == 1)
        let cancelled = DNSProbe()
        let cancellation = Task {
            try await WebsiteIconDNSResolver(start: cancelled.start).resolve(
                "www.example.com", deadline: .now.advanced(by: .seconds(2)))
        }
        try await cancelled.waitStarted()
        cancellation.cancel()
        await #expect(throws: CancellationError.self) { try await cancellation.value }
        #expect(cancelled.stops == 1)
        let expired = DNSProbe()
        await #expect(throws: WebsiteIconTransportError.deadline) {
            try await WebsiteIconDNSResolver(start: expired.start).resolve(
                "www.example.com", deadline: .now.advanced(by: .milliseconds(20)))
        }
        #expect(expired.stops == 1)
        let mixed = DNSProbe()
        let refusal = Task {
            try await WebsiteIconDNSResolver(start: mixed.start).resolve(
                "www.example.com", deadline: .now.advanced(by: .seconds(2)))
        }
        try await mixed.waitStarted()
        mixed.deliver(.success(.init(address: publicAddress, added: true, moreComing: true)))
        mixed.deliver(
            .success(
                .init(
                    address: WebsiteIconAddress(numeric: "::ffff:8.8.8.8")!, added: true,
                    moreComing: false)))
        await #expect(throws: WebsiteIconTransportError.dns) { try await refusal.value }
        #expect(mixed.stops == 1)
    }

    @Test func destinationRefusalHappensBeforeAnyConnector() async throws {
        let origin = try #require(
            WebsiteIconOrigin(url: "https://www.example.com/private?q=secret"))
        let probe = Counter()
        let transport = PinnedWebsiteIconTransport(
            resolve: { _, _ in
                [
                    WebsiteIconAddress(numeric: "8.8.8.8")!,
                    WebsiteIconAddress(numeric: "127.0.0.1")!,
                ]
            },
            connect: { _, _, _ in
                probe.increment()
                throw WebsiteIconTransportError.connection
            })
        await #expect(throws: WebsiteIconTransportError.refusedAddress) {
            try await transport.fetch(origin)
        }
        #expect(probe.value == 0)
    }

    @Test func trustRejectsUnknownRootWrongHostAndExpiredLeaf() async throws {
        for variant in 0..<3 {
            let trust = try Self.trust()
            if variant != 0 {
                #expect(
                    SecTrustSetAnchorCertificates(trust, [Self.root()] as CFArray) == errSecSuccess)
            }
            if variant == 2 {
                #expect(
                    SecTrustSetVerifyDate(
                        trust, Date(timeIntervalSince1970: 2_524_608_000) as CFDate)
                        == errSecSuccess)
            }
            await #expect(throws: WebsiteIconTransportError.trust) {
                try await WebsiteIconServerTrust.evaluate(
                    trust, host: variant == 1 ? "wrong.example.com" : "www.example.com",
                    deadline: .now.advanced(by: .seconds(3)))
            }
        }
        let trust = try Self.trust()
        #expect(SecTrustSetAnchorCertificates(trust, [Self.root()] as CFArray) == errSecSuccess)
        try await WebsiteIconServerTrust.evaluate(
            trust, host: "www.example.com", deadline: .now.advanced(by: .seconds(3)))
    }

    @Test func actualTLSChecksDefaultTrustBeforeSendingHTTP() async throws {
        let peer = try SyntheticIconPeer(response: try Self.image(type: .png))
        let server = peer.start()
        let transport = PinnedWebsiteIconTransport(
            resolve: { _, _ in [WebsiteIconAddress(numeric: "8.8.8.8")!] },
            connect: { _, deadline, _ in try peer.claimClient(deadline: deadline) })
        await #expect(throws: WebsiteIconTransportError.trust) {
            try await transport.fetch(WebsiteIconOrigin(url: "https://www.example.com")!)
        }
        peer.finish()
        _ = await server.value
        #expect(peer.request.isEmpty)
    }

    @Test(arguments: [false, true])
    func actualPinnedTLSUsesOriginalSNIAndOnlyFixedRequest(repeatedHeaders: Bool) async throws {
        let image = try Self.image(type: .png)
        let peer = try SyntheticIconPeer(
            response: image,
            headers: repeatedHeaders
                ? "Set-Cookie: first=secret\r\nset-cookie: second=private\r\nX-Trace-2: one\r\nX-Trace-2: two\r\nContent-Language: en\r\ncontent-language: fr\r\nContent-Type: image/png\r\ncontent-type: image/jpeg\r\n"
                : "")
        let server = peer.start()
        let probe = Counter()
        let transport = PinnedWebsiteIconTransport(
            resolve: { host, _ in
                #expect(host == "www.example.com")
                probe.increment()
                return [WebsiteIconAddress(numeric: "8.8.8.8")!]
            },
            connect: { address, deadline, _ in
                #expect(address == WebsiteIconAddress(numeric: "8.8.8.8"))
                return try peer.claimClient(deadline: deadline)
            },
            evaluateTrust: { trust, host, deadline in
                #expect(
                    SecTrustSetAnchorCertificates(trust, [Self.root()] as CFArray) == errSecSuccess)
                _ = SecTrustSetVerifyDate(
                    trust, Date(timeIntervalSince1970: 1_791_244_800) as CFDate)
                try await WebsiteIconServerTrust.evaluate(trust, host: host, deadline: deadline)
            })
        let outcome = await Task {
            try await transport.fetch(
                WebsiteIconOrigin(url: "https://www.example.com/private/path?token=secret")!)
        }.result
        peer.finish()
        _ = await server.value
        let result = try outcome.get()
        #expect(result == WebsiteIconImage.normalizedPNG(image) && probe.value == 1)
        #expect(peer.sni == "www.example.com")
        #expect(
            peer.request
                == String(
                    decoding: WebsiteIconSocket.request(host: "www.example.com"), as: UTF8.self))
        #expect(
            !peer.request.contains("secret") && !peer.request.contains("Authorization")
                && !peer.request.contains("Cookie"))
    }

    @Test func finishedPeerDrainsDelayedClientClosure() async throws {
        let peer = try SyntheticIconPeer(response: try Self.image(type: .png))
        let descriptor = try peer.claimClient(
            deadline: ContinuousClock.now.advanced(by: .seconds(5)))
        let server = peer.start()
        peer.finish()
        let close = Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            Darwin.close(descriptor)
        }
        _ = await close.value
        _ = await server.value
        #expect(peer.observedPeerClosure)
    }

    @Test func preparedPeersRemainAliveUntilHandoff() async throws {
        let image = try Self.image(type: .png)
        let first = try SyntheticIconPeer(response: image, responseByteLimit: 0)
        let second = try SyntheticIconPeer(response: image)
        let unused = try SyntheticIconPeer(response: image)
        let peers = [first, second, unused]
        let servers = peers.map { $0.start() }
        defer { for peer in peers { peer.finish() } }
        try await Task.sleep(for: .milliseconds(5_100))
        #expect(peers.allSatisfy { !$0.clientWasClaimed && $0.request.isEmpty })
        let addresses = ["8.8.8.8", "1.1.1.1", "9.9.9.9"].map { WebsiteIconAddress(numeric: $0)! }
        let attempts = NetworkAttempts()
        let transport = PinnedWebsiteIconTransport(
            resolve: { _, _ in addresses },
            connect: { address, deadline, _ in
                attempts.record(address, deadline)
                return try peers[addresses.firstIndex(of: address)!].claimClient(deadline: deadline)
            }, evaluateTrust: Self.anchoredTrust)
        let outcome = await Task {
            try await transport.fetch(WebsiteIconOrigin(url: "https://www.example.com")!)
        }.result
        for peer in peers { peer.finish() }
        for server in servers { _ = await server.value }
        #expect(try outcome.get() == WebsiteIconImage.normalizedPNG(image))
        #expect(attempts.addresses == Array(addresses.prefix(2)))
        #expect(!unused.clientWasClaimed && unused.observedPeerClosure)
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)])
    func exchangeDropRetriesTheNextPinnedAddress(handshake: Bool, graceful: Bool) async throws {
        let image = try Self.image(type: .png)
        let first = try SyntheticIconPeer(
            response: image, dropHandshake: handshake, responseByteLimit: handshake ? nil : 0,
            gracefulClose: graceful)
        let second = try SyntheticIconPeer(response: image)
        let servers = [first, second].map { $0.start() }
        let attempts = NetworkAttempts()
        let trusts = Counter()
        let addresses = [
            WebsiteIconAddress(numeric: "8.8.8.8")!, WebsiteIconAddress(numeric: "1.1.1.1")!,
        ]
        let transport = PinnedWebsiteIconTransport(
            resolve: { host, _ in
                #expect(host == "www.example.com")
                return addresses
            },
            connect: { address, deadline, _ in
                attempts.record(address, deadline)
                return try (address == addresses[0] ? first : second).claimClient(
                    deadline: deadline)
            },
            evaluateTrust: { trust, host, deadline in
                trusts.increment()
                try await Self.anchoredTrust(trust, host: host, deadline: deadline)
            })
        let outcome = await Task {
            try await transport.fetch(WebsiteIconOrigin(url: "https://www.example.com/private")!)
        }.result
        for peer in [first, second] { peer.finish() }
        for server in servers { _ = await server.value }
        #expect(attempts.addresses == addresses)
        #expect(attempts.deadlines.count == 2)
        if attempts.deadlines.count == 2 {
            #expect(attempts.deadlines[0] == attempts.deadlines[1])
        }
        #expect(try outcome.get() == WebsiteIconImage.normalizedPNG(image))
        #expect(trusts.value == (handshake ? 1 : 2))
        #expect(first.request.isEmpty == handshake)
        #expect(second.sni == "www.example.com")
        #expect(
            second.request
                == String(
                    decoding: WebsiteIconSocket.request(host: "www.example.com"), as: UTF8.self))
        #expect(second.observedPeerClosure)
    }

    @Test func retriesShareTheEncryptedByteBudget() async throws {
        let first = try SyntheticIconPeer(
            response: Data(repeating: 65, count: 80_000), responseByteLimit: 55_000)
        let second = try SyntheticIconPeer(
            response: Data(repeating: 65, count: 80_000), responseByteLimit: 55_000)
        let third = try SyntheticIconPeer(response: try Self.image(type: .png))
        let peers = [first, second, third]
        let servers = peers.map { $0.start() }
        let attempts = NetworkAttempts()
        let addresses = ["8.8.8.8", "1.1.1.1", "9.9.9.9"].map { WebsiteIconAddress(numeric: $0)! }
        let transport = PinnedWebsiteIconTransport(
            resolve: { _, _ in addresses },
            connect: { address, deadline, _ in
                attempts.record(address, deadline)
                return try peers[addresses.firstIndex(of: address)!].claimClient(deadline: deadline)
            }, evaluateTrust: Self.anchoredTrust)
        let outcome = await Task {
            try await transport.fetch(WebsiteIconOrigin(url: "https://www.example.com")!)
        }.result
        for peer in peers { peer.finish() }
        for server in servers { _ = await server.value }
        #expect(throws: WebsiteIconTransportError.tooLarge) { try outcome.get() }
        #expect(attempts.addresses == Array(addresses.prefix(2)))
        #expect(!third.clientWasClaimed && third.request.isEmpty)
        #expect(first.encryptedBytesWritten < WebsiteIconHTTPParser.bodyLimit)
        #expect(second.encryptedBytesWritten < WebsiteIconHTTPParser.bodyLimit)
        #expect(
            first.encryptedBytesWritten + second.encryptedBytesWritten
                >= WebsiteIconHTTPParser.bodyLimit)
    }

    @Test(arguments: ["trust", "redirect", "malformed", "tooLarge"])
    func terminalResponsesNeverTryAnAlternate(_ failure: String) async throws {
        let image = try Self.image(type: .png)
        let first = try SyntheticIconPeer(
            response: failure == "tooLarge" ? Data(repeating: 65, count: 250_000) : image,
            headers: failure == "malformed" ? "Content-Length: 1\r\n" : "",
            status: failure == "redirect" ? 302 : 200)
        let second = try SyntheticIconPeer(response: image)
        let peers = [first, second]
        let servers = peers.map { $0.start() }
        let attempts = Counter()
        let addresses = [
            WebsiteIconAddress(numeric: "8.8.8.8")!, WebsiteIconAddress(numeric: "1.1.1.1")!,
        ]
        let transport = PinnedWebsiteIconTransport(
            resolve: { _, _ in addresses },
            connect: { address, deadline, _ in
                attempts.increment()
                return try (address == addresses[0] ? first : second).claimClient(
                    deadline: deadline)
            },
            evaluateTrust: { trust, host, deadline in
                if failure == "trust" {
                    try await WebsiteIconServerTrust.evaluate(trust, host: host, deadline: deadline)
                } else {
                    try await Self.anchoredTrust(trust, host: host, deadline: deadline)
                }
            })
        let outcome = await Task {
            try await transport.fetch(WebsiteIconOrigin(url: "https://www.example.com")!)
        }.result
        for peer in peers { peer.finish() }
        for server in servers { _ = await server.value }
        let expected: WebsiteIconTransportError =
            failure == "trust"
            ? .trust
            : failure == "redirect"
                ? .status(302) : failure == "malformed" ? .invalidHTTP : .tooLarge
        #expect(throws: expected) { try outcome.get() }
        #expect(attempts.value == 1 && !second.clientWasClaimed && second.request.isEmpty)
        if failure == "trust" { #expect(first.request.isEmpty) }
    }

    @Test(arguments: [false, true])
    func terminalDeadlineAndCancellationNeverTryAnAlternate(cancelled: Bool) async throws {
        let cancellation = RequestCancellation()
        let first = try SyntheticIconPeer(
            response: try Self.image(type: .png), stall: true,
            onRequest: { if cancelled { cancellation.cancel() } })
        let second = try SyntheticIconPeer(response: try Self.image(type: .png))
        let peers = [first, second]
        let servers = peers.map { $0.start() }
        let attempts = Counter()
        let addresses = [
            WebsiteIconAddress(numeric: "8.8.8.8")!, WebsiteIconAddress(numeric: "1.1.1.1")!,
        ]
        let transport = PinnedWebsiteIconTransport(
            timeout: cancelled ? .seconds(5) : .milliseconds(100),
            resolve: { _, _ in addresses },
            connect: { address, deadline, _ in
                attempts.increment()
                return try (address == addresses[0] ? first : second).claimClient(
                    deadline: deadline)
            }, evaluateTrust: Self.anchoredTrust)
        let operation = Task {
            try await transport.fetch(WebsiteIconOrigin(url: "https://www.example.com")!)
        }
        cancellation.install { operation.cancel() }
        let outcome = await operation.result
        for peer in peers { peer.finish() }
        for server in servers { _ = await server.value }
        if cancelled {
            #expect(!first.request.isEmpty)
            #expect(throws: CancellationError.self) { try outcome.get() }
        } else {
            #expect(throws: WebsiteIconTransportError.deadline) { try outcome.get() }
        }
        #expect(attempts.value <= 1 && !second.clientWasClaimed && second.request.isEmpty)
    }

    @Test func activeTLSDeadlineAndCancellationCloseTheConnection() async throws {
        for cancelled in [false, true] {
            let cancellation = RequestCancellation()
            let peer = try SyntheticIconPeer(
                response: try Self.image(type: .png), stall: true,
                onRequest: { if cancelled { cancellation.cancel() } })
            let server = peer.start()
            let transport = PinnedWebsiteIconTransport(
                timeout: cancelled ? .seconds(3) : .milliseconds(100),
                resolve: { _, _ in [WebsiteIconAddress(numeric: "8.8.8.8")!] },
                connect: { _, deadline, _ in try peer.claimClient(deadline: deadline) },
                evaluateTrust: { trust, host, deadline in
                    #expect(
                        SecTrustSetAnchorCertificates(trust, [Self.root()] as CFArray)
                            == errSecSuccess)
                    _ = SecTrustSetVerifyDate(
                        trust, Date(timeIntervalSince1970: 1_791_244_800) as CFDate)
                    try await WebsiteIconServerTrust.evaluate(trust, host: host, deadline: deadline)
                })
            let operation = Task {
                try await transport.fetch(WebsiteIconOrigin(url: "https://www.example.com")!)
            }
            cancellation.install { operation.cancel() }
            if cancelled {
                await #expect(throws: CancellationError.self) { try await operation.value }
            } else {
                await #expect(throws: WebsiteIconTransportError.deadline) {
                    try await operation.value
                }
            }
            let acquired = peer.clientWasClaimed
            if !acquired {
                #expect(!cancelled && peer.request.isEmpty)
                peer.finish()
            }
            let reused = cancelled ? peer.reuseReleasedClientSlot() : -1
            if cancelled { #expect(reused >= 0) }
            defer { if reused >= 0 { Darwin.close(reused) } }
            peer.finish()
            _ = await server.value
            #expect(peer.observedPeerClosure)
            if cancelled { #expect(!peer.request.isEmpty && acquired) }
        }
    }

    @Test(arguments: [false, true])
    func deadlineBeforeConnectionLeavesFixtureOwnershipIntact(pressure: Bool) async throws {
        let peer = try SyntheticIconPeer(response: try Self.image(type: .png), stall: true)
        let server = peer.start()
        let work = (0..<(pressure ? 4 : 0)).map { _ in
            Task.detached(priority: .userInitiated) {
                let end = ContinuousClock.now.advanced(by: .milliseconds(200))
                var iterations = 0
                repeat { iterations &+= 1 } while ContinuousClock.now < end
                return iterations
            }
        }
        let connections = Counter()
        let transport = PinnedWebsiteIconTransport(
            timeout: .milliseconds(100),
            resolve: { _, deadline in
                try await Task.sleep(
                    until: deadline.advanced(by: .milliseconds(10)), clock: .continuous)
                return [WebsiteIconAddress(numeric: "8.8.8.8")!]
            },
            connect: { _, deadline, _ in
                connections.increment()
                return try peer.claimClient(deadline: deadline)
            })
        await #expect(throws: WebsiteIconTransportError.deadline) {
            try await transport.fetch(WebsiteIconOrigin(url: "https://www.example.com")!)
        }
        #expect(connections.value == 0 && !peer.clientWasClaimed)
        #expect(peer.request.isEmpty)
        peer.finish()
        _ = await server.value
        #expect(peer.observedPeerClosure)
        for task in work { #expect(await task.value > 0) }
    }

    @Test func concurrentAdmissionIsBoundedAndCancellationReleasesIt() async throws {
        let first = DNSProbe()
        let second = DNSProbe()
        func transport(_ probe: DNSProbe) -> PinnedWebsiteIconTransport {
            PinnedWebsiteIconTransport(
                resolve: { host, deadline in
                    try await WebsiteIconDNSResolver(start: probe.start).resolve(
                        host, deadline: deadline)
                }, connect: { _, _, _ in throw WebsiteIconTransportError.connection })
        }
        let origin = WebsiteIconOrigin(url: "https://www.example.com")!
        let firstTask = Task { try await transport(first).fetch(origin) }
        let secondTask = Task { try await transport(second).fetch(origin) }
        try await first.waitStarted()
        try await second.waitStarted()
        await #expect(throws: WebsiteIconTransportError.busy) {
            try await transport(DNSProbe()).fetch(origin)
        }
        firstTask.cancel()
        secondTask.cancel()
        await #expect(throws: CancellationError.self) { try await firstTask.value }
        await #expect(throws: CancellationError.self) { try await secondTask.value }
        #expect(first.stops == 1 && second.stops == 1)
        let next = PinnedWebsiteIconTransport(
            resolve: { _, _ in [] },
            connect: { _, _, _ in throw WebsiteIconTransportError.connection })
        await #expect(throws: WebsiteIconTransportError.refusedAddress) {
            try await next.fetch(origin)
        }
    }

    @Test func encryptedTLSStreamBudgetIncludesRecordOverhead() async throws {
        let peer = try SyntheticIconPeer(response: Data(repeating: 65, count: 250_000))
        let server = peer.start()
        let transport = PinnedWebsiteIconTransport(
            resolve: { _, _ in [WebsiteIconAddress(numeric: "8.8.8.8")!] },
            connect: { _, deadline, _ in try peer.claimClient(deadline: deadline) },
            evaluateTrust: { trust, host, deadline in
                #expect(
                    SecTrustSetAnchorCertificates(trust, [Self.root()] as CFArray) == errSecSuccess)
                _ = SecTrustSetVerifyDate(
                    trust, Date(timeIntervalSince1970: 1_791_244_800) as CFDate)
                try await WebsiteIconServerTrust.evaluate(trust, host: host, deadline: deadline)
            })
        await #expect(throws: WebsiteIconTransportError.tooLarge) {
            try await transport.fetch(WebsiteIconOrigin(url: "https://www.example.com")!)
        }
        peer.finish()
        _ = await server.value
        #expect(peer.clientWasClaimed && peer.observedPeerClosure)
    }

    fileprivate static func root() -> SecCertificate {
        SecCertificateCreateWithData(nil, IconTLSFixture.root as CFData)!
    }
    private static func anchoredTrust(
        _ trust: SecTrust, host: String, deadline: ContinuousClock.Instant
    ) async throws {
        #expect(SecTrustSetAnchorCertificates(trust, [root()] as CFArray) == errSecSuccess)
        #expect(
            SecTrustSetVerifyDate(trust, Date(timeIntervalSince1970: 1_791_244_800) as CFDate)
                == errSecSuccess)
        try await WebsiteIconServerTrust.evaluate(trust, host: host, deadline: deadline)
    }
    private static func trust() throws -> SecTrust {
        let leaf = try #require(SecCertificateCreateWithData(nil, IconTLSFixture.leaf as CFData))
        var trust: SecTrust?
        #expect(
            SecTrustCreateWithCertificates(
                [leaf, root()] as CFArray, SecPolicyCreateSSL(true, "www.example.com" as CFString),
                &trust) == errSecSuccess)
        #expect(
            SecTrustSetVerifyDate(trust!, Date(timeIntervalSince1970: 1_791_244_800) as CFDate)
                == errSecSuccess)
        return try #require(trust)
    }
    private static func image(type: UTType, width: Int = 32, height: Int = 16) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try #require(context.makeImage()),
            [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifUserComment: "secret synthetic metadata"
                ]
            ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
    private static func chunks(_ data: Data) throws -> [(String, Data)] {
        var chunks: [(String, Data)] = []
        var offset = 8
        while offset < data.count {
            let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            let payload = Data(data[offset + 4..<offset + 8 + length])
            let expected = data[offset + 8 + length..<offset + 12 + length].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            var crc: UInt32 = .max
            for byte in payload {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
            }
            #expect(~crc == expected)
            chunks.append(
                (String(decoding: payload.prefix(4), as: UTF8.self), Data(payload.dropFirst(4))))
            offset += length + 12
        }
        #expect(offset == data.count)
        return chunks
    }
}

private final class RequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var action: (@Sendable () -> Void)?
    func install(_ action: @escaping @Sendable () -> Void) {
        let cancel = lock.withLock {
            if requested { return true }
            self.action = action
            return false
        }
        if cancel { action() }
    }
    func cancel() {
        let action = lock.withLock {
            requested = true
            let action = self.action
            self.action = nil
            return action
        }
        action?()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class NetworkAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(WebsiteIconAddress, ContinuousClock.Instant)] = []
    var addresses: [WebsiteIconAddress] { lock.withLock { values.map(\.0) } }
    var deadlines: [ContinuousClock.Instant] { lock.withLock { values.map(\.1) } }
    func record(_ address: WebsiteIconAddress, _ deadline: ContinuousClock.Instant) {
        lock.withLock { values.append((address, deadline)) }
    }
}
private final class DNSProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: WebsiteIconDNSResolver.Receiver?
    private var closed = 0
    var stops: Int { lock.withLock { closed } }
    func start(
        _ host: String, queue: DispatchQueue, receive: @escaping WebsiteIconDNSResolver.Receiver
    ) throws -> (@Sendable () -> Void) {
        lock.withLock { receiver = receive }
        return { self.lock.withLock { self.closed += 1 } }
    }
    func deliver(_ result: Result<WebsiteIconDNSResolver.Answer, any Error>) {
        lock.withLock { receiver }?(result)
    }
    func waitStarted() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while lock.withLock({ receiver == nil }) {
            guard ContinuousClock.now < deadline else { throw WebsiteIconTransportError.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class SyntheticIconPeer: @unchecked Sendable {
    private let clientSlot: Int32
    private let server: Int32
    private let response: Data
    private let headers: String
    private let dropHandshake: Bool
    private let responseByteLimit: Int?
    private let gracefulClose: Bool
    private let status: Int
    private let identity: SecIdentity
    private let stall: Bool
    private let onRequest: @Sendable () -> Void
    private let lock = NSLock()
    private var received = ""
    private var serverName = ""
    private var unclaimedClient: Int32?
    private var claimed = false
    private var peerClosed = false
    private var encryptedWritten = 0
    private var wanted = Int16(POLLIN)
    private var deadline: ContinuousClock.Instant?
    private var cleanupDeadline: ContinuousClock.Instant?
    var request: String { lock.withLock { received } }
    var sni: String { lock.withLock { serverName } }
    var clientWasClaimed: Bool { lock.withLock { claimed } }
    var observedPeerClosure: Bool { lock.withLock { peerClosed } }
    var encryptedBytesWritten: Int { lock.withLock { encryptedWritten } }

    func claimClient(deadline: ContinuousClock.Instant) throws -> Int32 {
        try lock.withLock {
            guard let descriptor = unclaimedClient else {
                throw WebsiteIconTransportError.connection
            }
            unclaimedClient = nil
            self.deadline = deadline
            claimed = true
            return descriptor
        }
    }
    func finish() {
        lock.withLock {
            if cleanupDeadline == nil {
                cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            }
            if let descriptor = unclaimedClient {
                Darwin.close(descriptor)
                unclaimedClient = nil
            }
        }
    }
    deinit { finish() }
    func reuseReleasedClientSlot() -> Int32 {
        let opened = Darwin.open("/dev/null", O_RDONLY)
        guard opened >= 0 else { return -1 }
        if opened == clientSlot { return opened }
        // F_DUPFD cannot overwrite another test's newly reused descriptor.
        let reused = fcntl(opened, F_DUPFD, clientSlot)
        Darwin.close(opened)
        return reused
    }

    init(
        response: Data, stall: Bool = false, headers: String = "", dropHandshake: Bool = false,
        responseByteLimit: Int? = nil, gracefulClose: Bool = false, status: Int = 200,
        onRequest: @escaping @Sendable () -> Void = {}
    ) throws {
        self.response = response
        self.headers = headers
        self.dropHandshake = dropHandshake
        self.responseByteLimit = responseByteLimit
        self.gracefulClose = gracefulClose
        self.status = status
        self.stall = stall
        self.onRequest = onRequest
        var imported: CFArray?
        let options =
            [kSecImportExportPassphrase: "synthetic-only", kSecImportToMemoryOnly: true]
            as CFDictionary
        guard
            SecPKCS12Import(IconTLSFixture.identity as CFData, options, &imported) == errSecSuccess,
            let item = (imported as? [[CFString: Any]])?.first,
            let identity = item[kSecImportItemIdentity]
        else { throw WebsiteIconTransportError.trust }
        self.identity = identity as! SecIdentity
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listener >= 0 else { throw WebsiteIconTransportError.connection }
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            throw WebsiteIconTransportError.connection
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard
            withUnsafeMutablePointer(
                to: &address,
                {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(listener, $0, &length)
                    }
                }) == 0
        else { throw WebsiteIconTransportError.connection }
        let clientDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard
            withUnsafePointer(
                to: &address,
                {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(clientDescriptor, $0, length)
                    }
                }) == 0
        else {
            Darwin.close(clientDescriptor)
            throw WebsiteIconTransportError.connection
        }
        let serverDescriptor = Darwin.accept(listener, nil, nil)
        guard serverDescriptor >= 0 else {
            Darwin.close(clientDescriptor)
            throw WebsiteIconTransportError.connection
        }
        clientSlot = clientDescriptor
        unclaimedClient = clientDescriptor
        server = serverDescriptor
        _ = fcntl(server, F_SETFL, O_NONBLOCK)
        var enabled: Int32 = 1
        _ = setsockopt(
            server, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    func start() -> Task<Void, Never> {
        let queue = DispatchQueue(label: "capd.synthetic-icon-peer")
        return Task {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.serve()
                    continuation.resume()
                }
            }
        }
    }

    private func serve() {
        defer { Darwin.close(server) }
        if dropHandshake {
            var bytes = [UInt8](repeating: 0, count: 2048)
            while wait() {
                if Darwin.read(server, &bytes, bytes.count) > 0 {
                    if gracefulClose {
                        let alert: [UInt8] = [21, 3, 3, 0, 2, 1, 0]
                        guard Darwin.write(server, alert, alert.count) == alert.count else {
                            return
                        }
                        while wait(untilClientClosure: true) {
                            let count = Darwin.read(server, &bytes, bytes.count)
                            if count == 0 {
                                lock.withLock { peerClosed = true }
                                return
                            }
                            if count < 0, errno != EAGAIN, errno != EINTR { return }
                        }
                    }
                    return
                }
            }
            return
        }
        guard let context = SSLCreateContext(nil, .serverSide, .streamType) else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard SSLSetConnection(context, pointer) == errSecSuccess,
            SSLSetIOFuncs(
                context,
                { connection, bytes, length in
                    Unmanaged<SyntheticIconPeer>.fromOpaque(connection).takeUnretainedValue().read(
                        bytes, length)
                },
                { connection, bytes, length in
                    Unmanaged<SyntheticIconPeer>.fromOpaque(connection).takeUnretainedValue().write(
                        bytes, length)
                }) == errSecSuccess,
            SSLSetProtocolVersionMin(context, .tlsProtocol12) == errSecSuccess,
            SSLSetProtocolVersionMax(context, .tlsProtocol12) == errSecSuccess,
            SSLSetCertificate(context, [identity] as CFArray) == errSecSuccess
        else { return }
        while true {
            let result = SSLHandshake(context)
            if result == errSecSuccess { break }
            guard result == errSSLWouldBlock, wait() else { return }
        }
        var count = 0
        if SSLCopyRequestedPeerNameLength(context, &count) == errSecSuccess {
            var name = [UInt8](repeating: 0, count: count)
            if SSLCopyRequestedPeerName(context, &name, &count) == errSecSuccess {
                lock.withLock {
                    serverName = String(decoding: name.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: 2048)
        while !request.contains("\r\n\r\n") {
            var readCount = 0
            let result = SSLRead(context, &bytes, bytes.count, &readCount)
            if readCount > 0 {
                lock.withLock {
                    received += String(decoding: bytes.prefix(readCount), as: UTF8.self)
                }
            }
            guard received.count <= 4096 else { return }
            if request.contains("\r\n\r\n") { break }
            guard result == errSecSuccess || (result == errSSLWouldBlock && wait()) else { return }
        }
        onRequest()
        if stall {
            wanted = Int16(POLLIN)
            while wait(untilClientClosure: true) {
                let count = Darwin.read(server, &bytes, bytes.count)
                if count == 0 {
                    lock.withLock { peerClosed = true }
                    return
                }
                if count < 0 {
                    if errno == ECONNRESET { lock.withLock { peerClosed = true } }
                    return
                }
            }
            return
        }
        var reply = Data(
            "HTTP/1.1 \(status) Response\r\nContent-Length: \(response.count)\r\n\(headers)\r\n"
                .utf8)
        reply.append(response)
        let responseEnd = min(reply.count, responseByteLimit ?? reply.count)
        var offset = 0
        while offset < responseEnd {
            var written = 0
            let result = reply.withUnsafeBytes {
                SSLWrite(
                    context, $0.baseAddress!.advanced(by: offset), min(17, responseEnd - offset),
                    &written)
            }
            offset += written
            guard result == errSecSuccess || (result == errSSLWouldBlock && wait()) else { return }
        }
        if responseByteLimit != nil {
            if gracefulClose { _ = SSLClose(context) }
            return
        }
        _ = SSLClose(context)
        wanted = Int16(POLLIN)
        while wait(untilClientClosure: true) {
            let count = Darwin.read(server, &bytes, bytes.count)
            if count == 0 {
                lock.withLock { peerClosed = true }
                return
            }
            if count < 0 {
                if errno == ECONNRESET { lock.withLock { peerClosed = true } }
                return
            }
        }
    }
    private func wait(untilClientClosure: Bool = false) -> Bool {
        while true {
            let state = lock.withLock { (deadline, cleanupDeadline) }
            let end = state.1 ?? (untilClientClosure ? nil : state.0)
            if let end, ContinuousClock.now >= end { return false }
            var descriptor = pollfd(fd: server, events: wanted, revents: 0)
            let result = poll(&descriptor, 1, 25)
            if result > 0 { return true }
            if result < 0 && errno != EINTR { return false }
        }
    }
    private func read(_ bytes: UnsafeMutableRawPointer?, _ length: UnsafeMutablePointer<Int>)
        -> OSStatus
    {
        wanted = Int16(POLLIN)
        let requested = length.pointee
        let read = Darwin.read(server, bytes, requested)
        length.pointee = max(0, read)
        if read == 0 || (read < 0 && errno == ECONNRESET) { lock.withLock { peerClosed = true } }
        if read > 0 { return read == requested ? errSecSuccess : errSSLWouldBlock }
        return read == 0
            ? errSSLClosedAbort : (errno == EAGAIN || errno == EINTR ? errSSLWouldBlock : errSecIO)
    }
    private func write(_ bytes: UnsafeRawPointer?, _ length: UnsafeMutablePointer<Int>) -> OSStatus
    {
        wanted = Int16(POLLOUT)
        let requested = length.pointee
        let written = Darwin.write(server, bytes, requested)
        if written > 0 { lock.withLock { encryptedWritten += written } }
        length.pointee = max(0, written)
        if written < 0, errno == EPIPE || errno == ECONNRESET {
            lock.withLock { peerClosed = true }
        }
        return written >= 0
            ? (written == requested ? errSecSuccess : errSSLWouldBlock)
            : (errno == EAGAIN || errno == EINTR ? errSSLWouldBlock : errSecIO)
    }
}

// Synthetic identity stays in memory; it is never installed in a host keychain.
private enum IconTLSFixture {
    static let root = Data(
        base64Encoded:
            "MIIDFTCCAf2gAwIBAgIJAMmwSwglu6KAMA0GCSqGSIb3DQEBCwUAMCgxJjAkBgNVBAMMHUNhcGQgU3ludGhldGljIEljb24gVGVzdCBSb290MB4XDTI2MTAwNTIzMzMzM1oXDTM2MTAwMjIzMzMzM1owKDEmMCQGA1UEAwwdQ2FwZCBTeW50aGV0aWMgSWNvbiBUZXN0IFJvb3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDJWVQPC4PzG4l9wjZDZmR6Y03FAluDicbvCfep5sdSbjoXGWx1+juP2kJwz+i/NIbbAuMdGK5SvC/2hubvgQsHDB6N8gakwTRJNEGaWgtswCWdadEGIvRbOd4DyQxkLNdUE8OB3kWau3eWHPI35nnx4tJkm8ucYvPqvUwosE6L6f7K2whe7o1w1JTxRbUAqgpFypxaS2/woY2KVwZAGK1a576PFIRCaG4jjhjvp+a6azoVNWGbOdhSZFuAgMxt4U8PwEk7BkHDELQAJAsy9mSgqn2EtHMj2ViW1Xt5xP7blEhEtEP5WyyqPlXgrdk5VeUdmYkTieqeqrfWUThLN3U5AgMBAAGjQjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBQ0NTtN+s/efsB8Pi3TSojrYLEsZzANBgkqhkiG9w0BAQsFAAOCAQEAxNlpeWe7czos6yNd9PzBphxyBaG+QbJZ7AnZB6h38E9+ojm2pEM+pOL9M9d3ziV2qeTEDKfGfey+5TKaR2+58cWcXluogXliPT6dq3Pc4i+5U8Bb997fBHaqNrfpokRFYQ3Yvj5Ua/ApS0pBjWNcv0nAT2e0l8ZJnnbcnkHYXPQB/ayZVV/WI4Gvz8z2O7qKQL4M7g8LZT7+LICkGcBtKvrAyO4sCSkTtnE+E8r6Ah17rQaTgfpPWbOaMsbh9oyLtC5s2kTkKi6ciA7lXdDqmyLB+Bf/68h+QnJy63fPy5RDP5LsFoAX6x3TpRV0ho49tRDTAjoNYX9EA6ksVYZT7A=="
    )!
    static let leaf = Data(
        base64Encoded:
            "MIIDEDCCAfigAwIBAgIJAOeyaFJV486WMA0GCSqGSIb3DQEBCwUAMCgxJjAkBgNVBAMMHUNhcGQgU3ludGhldGljIEljb24gVGVzdCBSb290MB4XDTI2MTAwNTIzMzMzM1oXDTI3MTAwNTIzMzMzM1owGjEYMBYGA1UEAwwPd3d3LmV4YW1wbGUuY29tMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkuUZOV3f55RpWvJhvnZ8f5SeMTRp6Ia29K1PN2cCXWuaVwhFu0bGbgvZGN9M+kXsOA4keGobzy2zFRawP4TmV1NTWH8nk1DQAZh0O5yVPcwSqX3v36X6RCmXIx8Hln3o1dfAMIBvfd4I3lNDBBr7ZI30rpdF2k5FG81QkCUCGRdAMBRQWPpllxyvlcinAuLbziFI+p8yHSJiUj/2apvwG7eVMHl1wkBRPiyiTGiG3lzokAugiqRzl2i2jyVddZ4ZYoQrGibJWv4nrMCBqSETCD0LJZ/T+2UTgMMXIFzp1ga3dlrl+6Roudksy1GouLOCrSul4APXRkL1XHrVJ5yQBQIDAQABo0swSTAaBgNVHREEEzARgg93d3cuZXhhbXBsZS5jb20wCQYDVR0TBAIwADALBgNVHQ8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDQYJKoZIhvcNAQELBQADggEBAKfglkKTO8dwRWeybUccUJsp9eUOhFkKQOF3zLPM4wmjCvf7bckgxumMv152DTc70UbUueAaYWT0GAl8tZPzu/8SmjrwduMd/X5UU076T9u0ZKXxD0dGezNnaEukwMWzZtOiUDUbtBlxEY/wbqovYruHZYVlesKpgvwlZS27HY6KwZL39qz664kWRSvbIR+0RB28sDjBvMuXptcq9gfDJhHoYHVH9kijRSpLB2GxNWW3k7NG5gR64LkxRHnsphv00wQ2sW4t07Fgzy7zwFMnIj8yN2wAtOC8KbOdk0nboemXVhZnxVB9R6owwXBwAzGbpRNyfbciVvUoowptrRh6J8M="
    )!
    static let identity = Data(
        base64Encoded:
            "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"
    )!
}
