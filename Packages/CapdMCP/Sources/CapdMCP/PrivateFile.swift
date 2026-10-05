import CapdSync
import Darwin
import Foundation

/// Bounded private-file read through descriptors; no symlink component is followed.
public enum MCPPrivateFile {
    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/"), maximumBytes > 0 else {
            throw MCPFailure.invalidArguments
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            throw MCPFailure.invalidArguments
        }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw MCPFailure.forbidden }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw MCPFailure.forbidden }
            close(directory)
            directory = next
        }
        let fd = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MCPFailure.forbidden }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
            before.st_uid == geteuid(), (before.st_mode & 0o777) == 0o600, before.st_nlink == 1,
            before.st_size > 0, before.st_size <= maximumBytes
        else { throw MCPFailure.forbidden }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: min(4096, maximumBytes + 1))
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw MCPFailure.forbidden
            }
            output.append(contentsOf: buffer.prefix(count))
            guard output.count <= maximumBytes else { throw MCPFailure.capacity }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_mode == after.st_mode
        else { throw MCPFailure.forbidden }
        return output
    }
}

public enum MCPJSONSafety {
    public static func validate(_ data: Data, maximumBytes: Int = 65_536) -> Bool {
        data.count <= maximumBytes && boundedJSON(data)
            && (try? JSONDecoder().decode(JSONValue.self, from: data)) != nil
    }
}
