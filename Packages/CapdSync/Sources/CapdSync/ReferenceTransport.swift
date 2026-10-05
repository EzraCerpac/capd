import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Test-only messages. This framing has no production versioning or authentication.
public enum ReferenceRequest: Codable, Sendable {
    case apply(SyncOperation)
    case changes(cursor: Int64, limit: Int)
    case baseline
    case upload(BlobReference, offset: Int, chunk: Data, final: Bool)
    case download(BlobReference)
    case unavailable(Bool)
    case dropNextAcknowledgement
    case fixtureCreate(SharedCapture)
    case fixtureEdit(UUID, CaptureEdit)
    case fixtureDelete(UUID)
    case fixtureSync
    case fixturePull
    case fixtureCaptures
    case fixturePending
}

public enum ReferenceResponse: Codable, Sendable {
    case receipt(SyncReceipt)
    case page(FeedPage)
    case baseline(Baseline)
    case data(Data)
    case operations([SyncOperation])
    case captures([SharedCapture])
    case okay
    case failure(SyncError)
}

/// Synchronous, bounded test RPC to 127.0.0.1 only; never retries a dropped response.
public struct ReferenceTransport: SyncTransport {
    public let port: UInt16

    public init(port: UInt16) { self.port = port }

    public func request(_ request: ReferenceRequest) throws -> ReferenceResponse {
        guard port > 0 else { throw SyncError.transportDisconnected }
        let fd = try ReferenceSocket.make()
        defer { _ = close(fd) }
        var address = ReferenceSocket.address(port: port)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw SyncError.transportDisconnected }
        try ReferenceSocket.write(try SyncDatabase.encode(request), to: fd)
        let response = try SyncDatabase.decode(
            ReferenceResponse.self, ReferenceSocket.read(from: fd))
        if case .failure(let error) = response { throw error }
        return response
    }

    public func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        guard case .receipt(let receipt) = try request(.apply(operation)) else {
            throw SyncError.invalidOperation
        }
        return receipt
    }

    public func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        guard case .page(let page) = try request(.changes(cursor: cursor, limit: limit)) else {
            throw SyncError.invalidOperation
        }
        return page
    }

    public func baseline() throws -> Baseline {
        guard case .baseline(let baseline) = try request(.baseline) else {
            throw SyncError.invalidOperation
        }
        return baseline
    }

    public func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        guard case .okay = try request(.upload(blob, offset: offset, chunk: chunk, final: final))
        else {
            throw SyncError.invalidOperation
        }
    }

    public func download(_ blob: BlobReference) throws -> Data {
        guard case .data(let data) = try request(.download(blob)) else {
            throw SyncError.invalidOperation
        }
        return data
    }
}

/// A single-request-at-a-time listener on an ephemeral loopback port, for synthetic test processes.
public final class ReferenceListener {
    private let fd: Int32
    public let port: UInt16

    public init() throws {
        let socket = try ReferenceSocket.make()
        do {
            var address = ReferenceSocket.address(port: 0)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(socket, 16) == 0 else { throw SyncError.transportDisconnected }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(socket, $0, &length)
                }
            }
            guard result == 0 else { throw SyncError.transportDisconnected }
            fd = socket
            port = UInt16(bigEndian: address.sin_port)
        } catch {
            _ = close(socket)
            throw error
        }
    }

    deinit { _ = close(fd) }

    public func run(handle: (ReferenceRequest) throws -> ReferenceResponse?) throws {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw SyncError.transportDisconnected
            }
            defer { _ = close(connection) }
            do {
                try ReferenceSocket.configure(connection)
                let request = try SyncDatabase.decode(
                    ReferenceRequest.self, ReferenceSocket.read(from: connection))
                let response: ReferenceResponse?
                do { response = try handle(request) } catch let error as SyncError {
                    response = .failure(error)
                } catch { response = .failure(.invalidOperation) }
                if let response {
                    try ReferenceSocket.write(try SyncDatabase.encode(response), to: connection)
                }
            } catch {
                // An interrupted frame must not terminate the fixture authority or apply a partial operation.
                continue
            }
        }
    }
}

private enum ReferenceSocket {
    static let maximumFrameBytes = 16_777_216

    static func make() throws -> Int32 {
        #if canImport(Darwin)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw SyncError.transportDisconnected }
        do { try configure(fd) } catch {
            _ = close(fd)
            throw error
        }
        return fd
    }

    static func configure(_ fd: Int32) throws {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                == 0,
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                == 0
        else {
            throw SyncError.transportDisconnected
        }
        #if canImport(Darwin)
            var one: Int32 = 1
            guard
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    == 0
            else {
                throw SyncError.transportDisconnected
            }
        #endif
    }

    static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        return address
    }

    static func write(_ data: Data, to fd: Int32) throws {
        guard data.count <= maximumFrameBytes else { throw SyncError.invalidOperation }
        let count = UInt32(data.count)
        let prefix = Data([
            UInt8(count >> 24), UInt8(truncatingIfNeeded: count >> 16),
            UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count),
        ])
        let framed = prefix + data
        try framed.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                #if canImport(Darwin)
                    let count = send(
                        fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                #else
                    let count = send(
                        fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset,
                        Int32(MSG_NOSIGNAL))
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SyncError.transportDisconnected }
                offset += count
            }
        }
    }

    static func read(from fd: Int32) throws -> Data {
        let prefix = try readBytes(4, from: fd)
        let count = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumFrameBytes else { throw SyncError.invalidOperation }
        return try readBytes(count, from: fd)
    }

    static func readBytes(_ count: Int, from fd: Int32) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw SyncError.transportDisconnected }
                offset += received
            }
        }
        return data
    }
}
