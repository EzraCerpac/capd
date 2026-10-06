import CapdSync
import Darwin
import Foundation
import Security

public enum WebsiteIconTransportError: Error, Equatable, Sendable {
    case dns, refusedAddress, connection, trust, deadline, tooLarge, invalidHTTP, invalidImage, busy
    case status(Int)
}

/// Direct numeric HTTPS with system hostname trust. SecureTransport limits this transport to TLS 1.2.
/// Numeric sockets bypass application proxy settings; hostname-triggered VPN activation is not guaranteed.
public struct PinnedWebsiteIconTransport: Sendable {
    typealias Resolver =
        @Sendable (String, ContinuousClock.Instant) async throws -> [WebsiteIconAddress]
    typealias Connector =
        @Sendable (WebsiteIconAddress, ContinuousClock.Instant, WebsiteIconCancellation) throws ->
        Int32
    typealias TrustEvaluator =
        @Sendable (SecTrust, String, ContinuousClock.Instant) async throws -> Void
    private let resolve: Resolver
    private let connect: Connector
    private let evaluateTrust: TrustEvaluator
    private let timeout: Duration
    private static let limiter = Limiter()

    public init() {
        resolve = { try await WebsiteIconDNSResolver().resolve($0, deadline: $1) }
        connect = WebsiteIconSocket.connect
        evaluateTrust = WebsiteIconServerTrust.evaluate
        timeout = .seconds(5)
    }

    init(
        timeout: Duration = .seconds(5), resolve: @escaping Resolver,
        connect: @escaping Connector,
        evaluateTrust: @escaping TrustEvaluator = WebsiteIconServerTrust.evaluate
    ) {
        self.timeout = timeout
        self.resolve = resolve
        self.connect = connect
        self.evaluateTrust = evaluateTrust
    }

    /// Returns only a validated static 64-by-64 sRGB PNG. No source metadata is retained.
    public func fetch(_ origin: WebsiteIconOrigin) async throws -> Data {
        try Task.checkCancellation()
        try await Self.limiter.acquire()
        do {
            let result = try await fetchPermitted(origin)
            await Self.limiter.release()
            return result
        } catch {
            await Self.limiter.release()
            throw error
        }
    }

    private func fetchPermitted(_ origin: WebsiteIconOrigin) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let addresses = try await resolve(origin.host, deadline)
        try Task.checkCancellation()
        guard !addresses.isEmpty, addresses.count <= 16,
            addresses.allSatisfy(WebsiteIconAddressPolicy.isPublic)
        else { throw WebsiteIconTransportError.refusedAddress }
        let cancellation = WebsiteIconCancellation()
        let streamBudget = WebsiteIconStreamBudget()
        let worker = Task.detached(priority: .utility) {
            try cancellation.check(deadline)
            var lastError: any Error = WebsiteIconTransportError.connection
            for address in addresses {
                try cancellation.check(deadline)
                guard streamBudget.remaining > 0 else { throw WebsiteIconTransportError.tooLarge }
                let descriptor: Int32
                do { descriptor = try connect(address, deadline, cancellation) } catch {
                    guard error as? WebsiteIconTransportError == .connection else { throw error }
                    lastError = error
                    continue
                }
                let socket = WebsiteIconSocket(
                    descriptor: descriptor, deadline: deadline, cancellation: cancellation,
                    streamBudget: streamBudget)
                defer { socket.close() }
                let data: Data
                do {
                    data = try await socket.exchange(
                        host: origin.host, evaluateTrust: evaluateTrust)
                } catch {
                    guard error as? WebsiteIconTransportError == .connection else { throw error }
                    lastError = error
                    continue
                }
                try cancellation.check(deadline)
                guard let normalized = WebsiteIconImage.normalizedPNG(data) else {
                    throw WebsiteIconTransportError.invalidImage
                }
                try cancellation.check(deadline)
                return normalized
            }
            throw lastError
        }
        return try await withTaskCancellationHandler {
            let data = try await worker.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }

    private actor Limiter {
        private var active = 0
        func acquire() throws {
            guard active < 2 else { throw WebsiteIconTransportError.busy }
            active += 1
        }
        func release() { active -= 1 }
    }
}

final class WebsiteIconCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check(_ deadline: ContinuousClock.Instant) throws {
        guard !lock.withLock({ cancelled }) else { throw CancellationError() }
        guard ContinuousClock.now < deadline else { throw WebsiteIconTransportError.deadline }
    }
}

final class WebsiteIconStreamBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0
    var remaining: Int { lock.withLock { WebsiteIconHTTPParser.bodyLimit - received } }
    func consume(_ count: Int) throws {
        try lock.withLock {
            guard count >= 0, count <= WebsiteIconHTTPParser.bodyLimit - received else {
                throw WebsiteIconTransportError.tooLarge
            }
            received += count
        }
    }
}

final class WebsiteIconSocket: @unchecked Sendable {
    private var descriptor: Int32
    private let deadline: ContinuousClock.Instant
    private let cancellation: WebsiteIconCancellation
    private var wantedEvents = Int16(POLLIN)
    private let streamBudget: WebsiteIconStreamBudget
    private var connectionFailed = false
    private var streamLimitReached = false

    init(
        descriptor: Int32, deadline: ContinuousClock.Instant, cancellation: WebsiteIconCancellation,
        streamBudget: WebsiteIconStreamBudget = WebsiteIconStreamBudget()
    ) {
        self.descriptor = descriptor
        self.deadline = deadline
        self.cancellation = cancellation
        self.streamBudget = streamBudget
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    static func connect(
        _ address: WebsiteIconAddress, deadline: ContinuousClock.Instant,
        cancellation: WebsiteIconCancellation
    ) throws -> Int32 {
        guard WebsiteIconAddressPolicy.isPublic(address) else {
            throw WebsiteIconTransportError.refusedAddress
        }
        try cancellation.check(deadline)
        let descriptor = Darwin.socket(address.family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw WebsiteIconTransportError.connection }
        let socket = WebsiteIconSocket(
            descriptor: descriptor, deadline: deadline, cancellation: cancellation)
        do {
            try socket.configure()
            let status = address.withSocketAddress { Darwin.connect(descriptor, $0, $1) }
            if status != 0 {
                guard errno == EINPROGRESS else { throw WebsiteIconTransportError.connection }
                try socket.wait(events: Int16(POLLOUT))
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0
                else { throw WebsiteIconTransportError.connection }
            }
            try cancellation.check(deadline)
            return descriptor
        } catch {
            socket.close()
            throw error
        }
    }

    private func configure() throws {
        let flags = fcntl(descriptor, F_GETFL)
        var enabled: Int32 = 1
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
            fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
            setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                == 0
        else { throw WebsiteIconTransportError.connection }
    }

    func exchange(host: String, evaluateTrust: PinnedWebsiteIconTransport.TrustEvaluator)
        async throws -> Data
    {
        try configure()
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw WebsiteIconTransportError.connection
        }
        try setup(context, host: host)
        var trusted = false
        while true {
            try check()
            let status = SSLHandshake(context)
            try check()
            if status == errSSLPeerAuthCompleted {
                guard !trusted else { throw WebsiteIconTransportError.trust }
                var trust: SecTrust?
                guard SSLCopyPeerTrust(context, &trust) == errSecSuccess, let trust else {
                    throw WebsiteIconTransportError.trust
                }
                try await evaluateTrust(trust, host, deadline)
                try check()
                trusted = true
            } else if status == errSSLWouldBlock {
                try wait(events: wantedEvents)
            } else if status == errSecSuccess {
                guard trusted else { throw WebsiteIconTransportError.trust }
                break
            } else {
                throw connectionFailed || status == errSSLClosedGraceful
                    || status == errSSLClosedAbort
                    ? WebsiteIconTransportError.connection : WebsiteIconTransportError.trust
            }
        }
        let request = Self.request(host: host)
        var sent = 0
        while sent < request.count {
            try check()
            var count = 0
            let status = request.withUnsafeBytes {
                SSLWrite(context, $0.baseAddress!.advanced(by: sent), request.count - sent, &count)
            }
            try check()
            sent += count
            guard status == errSecSuccess || status == errSSLWouldBlock else {
                throw WebsiteIconTransportError.connection
            }
            if status == errSSLWouldBlock { try wait(events: wantedEvents) }
        }
        var parser = WebsiteIconHTTPParser()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while parser.response == nil {
            try check()
            var count = 0
            let status = SSLRead(context, &bytes, bytes.count, &count)
            try check()
            if count > 0 { try parser.append(Data(bytes.prefix(count))) }
            if parser.response != nil { break }
            if status == errSSLWouldBlock {
                try wait(events: wantedEvents)
            } else if status == errSSLClosedGraceful {
                throw WebsiteIconTransportError.connection
            } else if status != errSecSuccess {
                throw WebsiteIconTransportError.connection
            }
        }
        try check()
        return try parser.end().body
    }

    static func request(host: String) -> Data {
        Data(
            ("GET /favicon.ico HTTP/1.1\r\nHost: \(host)\r\n"
                + "Accept: image/png,image/jpeg,image/x-icon\r\nAccept-Encoding: identity\r\n"
                + "Connection: close\r\n\r\n").utf8)
    }

    private func setup(_ context: SSLContext, host: String) throws {
        let connection = Unmanaged.passUnretained(self).toOpaque()
        guard SSLSetConnection(context, connection) == errSecSuccess,
            SSLSetIOFuncs(
                context,
                { connection, data, length in
                    return Unmanaged<WebsiteIconSocket>.fromOpaque(connection).takeUnretainedValue()
                        .read(data, length)
                },
                { connection, data, length in
                    return Unmanaged<WebsiteIconSocket>.fromOpaque(connection).takeUnretainedValue()
                        .write(data, length)
                }) == errSecSuccess,
            SSLSetProtocolVersionMin(context, .tlsProtocol12) == errSecSuccess,
            SSLSetProtocolVersionMax(context, .tlsProtocol12) == errSecSuccess,
            SSLSetSessionOption(context, .breakOnServerAuth, true) == errSecSuccess,
            SSLSetSessionOption(context, .breakOnCertRequested, true) == errSecSuccess,
            SSLSetSessionOption(context, .falseStart, false) == errSecSuccess,
            SSLSetSessionOption(context, .allowRenegotiation, false) == errSecSuccess,
            SSLSetSessionOption(context, .enableSessionTickets, false) == errSecSuccess,
            host.withCString({ SSLSetPeerDomainName(context, $0, host.utf8.count) })
                == errSecSuccess
        else { throw WebsiteIconTransportError.trust }
    }

    private func check() throws {
        try cancellation.check(deadline)
        guard !streamLimitReached else { throw WebsiteIconTransportError.tooLarge }
    }

    private func wait(events: Int16) throws {
        while true {
            try check()
            var descriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&descriptor, 1, 50)
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                    throw WebsiteIconTransportError.connection
                }
                return
            }
            if result < 0, errno != EINTR { throw WebsiteIconTransportError.connection }
        }
    }

    private func read(_ data: UnsafeMutableRawPointer?, _ length: UnsafeMutablePointer<Int>)
        -> OSStatus
    {
        do { try check() } catch {
            length.pointee = 0
            return errSecUserCanceled
        }
        wantedEvents = Int16(POLLIN)
        let requested = length.pointee
        let remaining = streamBudget.remaining
        guard remaining > 0 else {
            streamLimitReached = true
            length.pointee = 0
            return errSecIO
        }
        let count = Darwin.read(descriptor, data, min(requested, remaining))
        if count > 0 {
            do { try streamBudget.consume(count) } catch {
                streamLimitReached = true
                length.pointee = 0
                return errSecIO
            }
            length.pointee = count
            return count == requested ? errSecSuccess : errSSLWouldBlock
        }
        length.pointee = 0
        if count == 0 {
            connectionFailed = true
            return errSSLClosedAbort
        }
        if errno == EAGAIN || errno == EINTR { return errSSLWouldBlock }
        connectionFailed = true
        return errSecIO
    }

    private func write(_ data: UnsafeRawPointer?, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
        do { try check() } catch {
            length.pointee = 0
            return errSecUserCanceled
        }
        wantedEvents = Int16(POLLOUT)
        let count = Darwin.write(descriptor, data, length.pointee)
        if count >= 0 {
            let requested = length.pointee
            length.pointee = count
            return count == requested ? errSecSuccess : errSSLWouldBlock
        }
        length.pointee = 0
        if errno == EAGAIN || errno == EINTR { return errSSLWouldBlock }
        connectionFailed = true
        return errSecIO
    }
}
