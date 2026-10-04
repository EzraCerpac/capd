import Darwin
import Foundation
import XCTest

@testable import CapdSyncServerHost

final class MCPSocketProtectionFailureTests: XCTestCase {
    private enum SyntheticFailure: Error {
        case protectionDenied
        case pathTooLong
    }

    func testBoundSocketIsRemovedWhenProtectionFails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let socketURL = directory.appendingPathComponent("bridge.sock")
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketURL.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw SyntheticFailure.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        let protected = HostHTTP.protectMCPBoundSocket(socketURL) { _ in
            throw SyntheticFailure.protectionDenied
        }

        XCTAssertFalse(protected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
    }
}
