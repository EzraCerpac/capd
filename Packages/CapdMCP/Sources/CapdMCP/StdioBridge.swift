import CapdSync
import Darwin
import Foundation

/// Delimited framing never allocates an unbounded line, including malformed input.
public final class MCPFrameReader {
    private let input: FileHandle
    private var pending = Data()
    private var ended = false
    public init(input: FileHandle) { self.input = input }
    public func next() throws -> Data? {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard line.count <= 65_536 else { throw MCPFailure.capacity }
                return line
            }
            guard pending.count <= 65_536 else { throw MCPFailure.capacity }
            if ended {
                guard !pending.isEmpty else { return nil }
                let last = pending
                pending.removeAll()
                return last
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(input.fileDescriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw MCPFailure.unavailable }
            if count == 0 { ended = true } else { pending.append(contentsOf: buffer.prefix(count)) }
        }
    }
}

public struct MCPStdioBridge: Sendable {
    public typealias Sender = @Sendable (URLRequest) throws -> MCPHTTPResponse
    private let credentialURL: URL
    private let endpoint: URL
    private let sender: Sender
    public init(
        credentialURL: URL, socketURL: URL, sender: Sender? = nil
    ) throws {
        guard credentialURL.isFileURL, socketURL.isFileURL else {
            throw MCPFailure.invalidArguments
        }
        self.credentialURL = credentialURL
        self.endpoint = URL(string: "http://capd.local/mcp")!
        self.sender = sender ?? { try MCPUnixSocket.send($0, socketURL: socketURL) }
    }
    public func forward(_ line: Data) -> Data? {
        var id: JSONValue = .null
        var notification = false
        do {
            guard MCPJSONSafety.validate(line),
                let message = try JSONDecoder().decode(JSONValue.self, from: line).object,
                message["jsonrpc"] == .string("2.0"), let method = message["method"]?.string,
                Set(message.keys).isSubset(of: ["jsonrpc", "id", "method", "params"])
            else { throw MCPFailure.invalidArguments }
            if let value = message["id"] {
                guard value.string != nil || value.integer != nil,
                    value.string?.utf8.count ?? 0 <= 256
                else { throw MCPFailure.invalidArguments }
                id = value
            } else {
                notification = true
            }
            guard
                [
                    "initialize", "ping", "server/discover", "tools/list", "tools/call",
                    "notifications/initialized", "notifications/cancelled",
                ].contains(method),
                message["params"] == nil || message["params"]?.object != nil
            else { throw MCPFailure.invalidArguments }
            let params = message["params"]?.object ?? [:]
            if method == "tools/call" {
                guard let name = params["name"]?.string,
                    [
                        "search_captures", "get_capture", "list_recent", "create_capture",
                        "edit_capture",
                    ].contains(name)
                else { throw MCPFailure.invalidArguments }
            }
            let bytes = try MCPPrivateFile.read(credentialURL, maximumBytes: 66)
            guard let value = String(data: bytes, encoding: .utf8) else {
                throw MCPFailure.forbidden
            }
            let bearer = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard bearer.utf8.count == 64,
                bearer.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw MCPFailure.forbidden }
            var request = URLRequest(
                url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: 6)
            request.httpMethod = "POST"
            request.httpBody = line
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let meta = params["_meta"]?.object,
                let version = meta["io.modelcontextprotocol/protocolVersion"]?.string
            {
                guard version.utf8.count <= 32,
                    version.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
                    method.unicodeScalars.allSatisfy({ (33...126).contains($0.value) })
                else { throw MCPFailure.invalidArguments }
                request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
                request.setValue(method, forHTTPHeaderField: "MCP-Method")
                if method == "tools/call", let name = params["name"]?.string {
                    request.setValue(name, forHTTPHeaderField: "MCP-Name")
                }
            }
            let reply = try sender(request)
            if notification { return nil }
            if reply.body.count <= 65_536, MCPJSONSafety.validate(reply.body),
                let object = try? JSONDecoder().decode(JSONValue.self, from: reply.body).object,
                object["jsonrpc"] == .string("2.0"), object["id"] == id,
                (object["result"] != nil) != (object["error"] != nil),
                (200...299).contains(reply.status) || object["error"] != nil
            {
                return reply.body
            }
            return Self.error(
                id,
                reply.status == 504
                    ? "Outcome may be unknown; retry identical operation_id, sequence and arguments without renumbering"
                    : "CAPD bridge unavailable; retry identical write identity without renumbering")
        } catch {
            if notification { return nil }
            return Self.error(
                id,
                "CAPD bridge refused request; retry writes with identical operation_id, sequence and arguments"
            )
        }
    }
    private static func error(_ id: JSONValue, _ message: String) -> Data {
        (try? JSONEncoder().encode(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object(["code": .number(-32000), "message": .string(message)]),
            ]))) ?? Data()
    }
}
