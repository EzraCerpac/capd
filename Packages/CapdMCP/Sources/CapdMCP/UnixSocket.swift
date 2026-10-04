import Darwin
import Foundation

/// Local transport authenticated by a private path and the kernel's peer UID.
/// The authority UID and root are trusted; no TCP, proxy or redirect fallback exists.
public enum MCPUnixSocket {
    public static func validatePath(_ url: URL, mustExist: Bool) throws {
        try validate(url, mustExist: mustExist, requirePrivateSocket: true)
    }

    public static func protectBoundSocket(_ url: URL) throws {
        try validate(url, mustExist: true, requirePrivateSocket: false)
        guard chmod(url.path, 0o600) == 0 else { throw MCPFailure.forbidden }
        try validatePath(url, mustExist: true)
    }

    /// Removes an owned socket from a trusted private directory after startup failure.
    public static func removeBoundSocket(_ url: URL) throws {
        try validate(url, mustExist: true, requirePrivateSocket: false)
        guard unlink(url.path) == 0 else { throw MCPFailure.forbidden }
    }

    private static func validate(_ url: URL, mustExist: Bool, requirePrivateSocket: Bool) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count < 104 else {
            throw MCPFailure.invalidArguments
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count > 1, !components.contains(".."), !components.contains(".") else {
            throw MCPFailure.invalidArguments
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw MCPFailure.forbidden }
        defer { close(fd) }
        for (index, component) in components.dropLast().enumerated() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw MCPFailure.forbidden }
            close(fd)
            fd = next
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == 0 || info.st_uid == geteuid() else {
                throw MCPFailure.forbidden
            }
            let writable = info.st_mode & 0o022 != 0
            guard !writable || (info.st_uid == 0 && info.st_mode & S_ISVTX != 0) else {
                throw MCPFailure.forbidden
            }
            if index == components.count - 2 {
                guard info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                    throw MCPFailure.forbidden
                }
            }
        }
        var info = stat()
        let result = fstatat(fd, components.last!, &info, AT_SYMLINK_NOFOLLOW)
        if !mustExist {
            guard result != 0, errno == ENOENT else { throw MCPFailure.forbidden }
            return
        }
        guard result == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(),
            !requirePrivateSocket || info.st_mode & 0o777 == 0o600
        else { throw MCPFailure.forbidden }
    }

    public static func send(_ request: URLRequest, socketURL: URL) throws -> MCPHTTPResponse {
        try validatePath(socketURL, mustExist: true)
        guard request.httpMethod == "POST", request.url?.absoluteString == "http://capd.local/mcp",
            let body = request.httpBody, body.count <= 65_536
        else { throw MCPFailure.invalidArguments }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPFailure.unavailable }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            throw MCPFailure.unavailable
        }
        var noSignal: Int32 = 1
        guard
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                == 0
        else {
            throw MCPFailure.unavailable
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let deadline = DispatchTime.now() + .seconds(6)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw MCPFailure.unavailable }
            try ready(fd, event: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
                throw MCPFailure.unavailable
            }
        }
        // Check BEFORE sending the bearer. The peer cannot claim a UID in protocol data.
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            throw MCPFailure.forbidden
        }
        var head =
            "POST /mcp HTTP/1.1\r\nHost: capd.local\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            guard name.utf8.count <= 64, value.utf8.count <= 1024,
                name.unicodeScalars.allSatisfy({ (33...126).contains($0.value) && $0.value != 58 }),
                value.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }),
                !["host", "connection", "content-length", "transfer-encoding"].contains(
                    name.lowercased())
            else { throw MCPFailure.invalidArguments }
            head += "\(name): \(value)\r\n"
        }
        guard head.utf8.count <= 16_384 else { throw MCPFailure.capacity }
        let output = Data((head + "\r\n").utf8) + body
        var sent = 0
        while sent < output.count {
            try ready(fd, event: Int16(POLLOUT), deadline: deadline)
            let count = output.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: sent), output.count - sent)
            }
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw MCPFailure.unavailable }
            sent += count
        }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Int?
        var status = 0
        var length = 0
        while true {
            if let headerEnd, received.count >= headerEnd + length {
                guard received.count == headerEnd + length else { throw MCPFailure.unavailable }
                return MCPHTTPResponse(status: status, body: Data(received.dropFirst(headerEnd)))
            }
            try ready(fd, event: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw MCPFailure.unavailable }
            received.append(contentsOf: buffer.prefix(count))
            guard received.count <= 16_384 + 65_536 else { throw MCPFailure.capacity }
            if headerEnd == nil {
                if let range = received.range(of: Data("\r\n\r\n".utf8)) {
                    guard range.upperBound <= 16_384,
                        let text = String(data: received[..<range.lowerBound], encoding: .utf8)
                    else { throw MCPFailure.capacity }
                    let lines = text.components(separatedBy: "\r\n")
                    let first = lines[0].split(separator: " ")
                    guard first.count >= 2, first[0] == "HTTP/1.1", let code = Int(first[1]),
                        (200...599).contains(code)
                    else { throw MCPFailure.unavailable }
                    var fields: [String: String] = [:]
                    for line in lines.dropFirst() {
                        guard let colon = line.firstIndex(of: ":") else {
                            throw MCPFailure.unavailable
                        }
                        let key = line[..<colon].lowercased()
                        guard fields[key] == nil else { throw MCPFailure.unavailable }
                        fields[key] = line[line.index(after: colon)...].trimmingCharacters(
                            in: .whitespaces)
                    }
                    guard fields["transfer-encoding"] == nil,
                        let size = fields["content-length"].flatMap(Int.init),
                        (0...65_536).contains(size)
                    else { throw MCPFailure.unavailable }
                    headerEnd = range.upperBound
                    status = code
                    length = size
                } else if received.count > 16_384 {
                    throw MCPFailure.capacity
                }
            }
        }
    }

    private static func ready(_ fd: Int32, event: Int16, deadline: DispatchTime) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw MCPFailure.unavailable }
            let remaining = Int32(
                min(6000, (deadline.uptimeNanoseconds - now + 999_999) / 1_000_000))
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let count = poll(&descriptor, 1, remaining)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, descriptor.revents & Int16(POLLERR | POLLNVAL) == 0,
                descriptor.revents & (event | Int16(POLLHUP)) != 0
            else { throw MCPFailure.unavailable }
            return
        }
    }
}
