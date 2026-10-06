import Foundation

public enum WebsiteIconPNG {
    /// Checks the bounded, metadata-free normalized PNG envelope; hosts still decode pixels.
    public static func validate(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count <= 262_144, bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw SyncError.invalidBlob
        }
        func integer(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        func crc(_ range: Range<Int>) -> UInt32 {
            var value = UInt32.max
            for byte in bytes[range] {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb8_8320 : 0) }
            }
            return value ^ UInt32.max
        }
        var offset = 8
        var header = false
        var pixels = false
        var endedPixels = false
        while offset < bytes.count {
            guard bytes.count - offset >= 12 else { throw SyncError.invalidBlob }
            let count = Int(integer(offset))
            guard count <= bytes.count - offset - 12 else { throw SyncError.invalidBlob }
            let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii)
            let payload = offset + 8
            let end = payload + count
            guard crc(offset + 4..<end) == integer(end) else { throw SyncError.invalidBlob }
            switch type {
            case "IHDR":
                guard !header, offset == 8, count == 13, integer(payload) == 64,
                    integer(payload + 4) == 64, bytes[payload + 8] == 8,
                    [2, 6].contains(bytes[payload + 9]), bytes[payload + 10] == 0,
                    bytes[payload + 11] == 0, bytes[payload + 12] == 0
                else { throw SyncError.invalidBlob }
                header = true
            case "IDAT":
                guard header, !endedPixels, count > 0 else { throw SyncError.invalidBlob }
                pixels = true
            case "IEND":
                guard header, pixels, count == 0, end + 4 == bytes.count else {
                    throw SyncError.invalidBlob
                }
                endedPixels = true
            default: throw SyncError.invalidBlob
            }
            offset = end + 4
        }
        guard endedPixels else { throw SyncError.invalidBlob }
    }
}
