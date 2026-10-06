import Darwin
import Foundation

struct WebsiteIconAddress: Equatable, Sendable {
    let family: Int32
    let bytes: [UInt8]

    init?(numeric: String) {
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, numeric, &v4) == 1 {
            family = AF_INET
            bytes = withUnsafeBytes(of: v4) { Array($0) }
        } else if inet_pton(AF_INET6, numeric, &v6) == 1 {
            family = AF_INET6
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            return nil
        }
    }

    init?(socketAddress: UnsafePointer<sockaddr>) {
        let family = Int32(socketAddress.pointee.sa_family)
        if family == AF_INET {
            let value = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in.self)
            self.family = family
            bytes = withUnsafeBytes(of: value.pointee.sin_addr) { Array($0) }
        } else if family == AF_INET6 {
            let value = UnsafeRawPointer(socketAddress).assumingMemoryBound(to: sockaddr_in6.self)
            guard value.pointee.sin6_scope_id == 0 else { return nil }
            self.family = family
            bytes = withUnsafeBytes(of: value.pointee.sin6_addr) { Array($0) }
        } else {
            return nil
        }
    }

    func withSocketAddress<T>(
        port: UInt16 = 443, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    )
        rethrows -> T
    {
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: bytes) }
            return try withUnsafePointer(to: &address) {
                try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    try body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        withUnsafeMutableBytes(of: &address.sin6_addr) { $0.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
    }
}

enum WebsiteIconAddressPolicy {
    static func isPublic(_ address: WebsiteIconAddress) -> Bool {
        let b = address.bytes
        if address.family == AF_INET, b.count == 4 {
            return b[0] != 0 && b[0] != 10 && b[0] != 127 && b[0] < 224
                && !(b[0] == 100 && (64...127).contains(b[1]))
                && !(b[0] == 169 && b[1] == 254)
                && !(b[0] == 172 && (16...31).contains(b[1]))
                && !(b[0] == 192
                    && (b[1] == 168 || (b[1] == 0 && b[2] == 0)
                        || (b[1] == 0 && b[2] == 2) || (b[1] == 88 && b[2] == 99)))
                && !(b[0] == 198 && ((18...19).contains(b[1]) || (b[1] == 51 && b[2] == 100)))
                && !(b[0] == 203 && b[1] == 0 && b[2] == 113)
        }
        guard address.family == AF_INET6, b.count == 16, b[0] & 0xE0 == 0x20 else { return false }
        return !(b[0] == 0x20 && b[1] == 0x02)
            && !(b[0] == 0x20 && b[1] == 0x01 && b[2] < 2)
            && !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8)
            && !(b[0] == 0x3F && b[1] == 0xFE)
            && !(b[0] == 0x3F && b[1] == 0xFF && b[2] & 0xF0 == 0)
    }
}
