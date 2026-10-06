import Foundation

struct WebsiteIconHTTPResponse: Sendable, Equatable {
    let status: Int
    let body: Data
}

struct WebsiteIconHTTPParser {
    static let bodyLimit = 256 * 1024
    static let headerLimit = 16 * 1024
    static let framingLimit = 16 * 1024
    private static let fieldNamePunctuation = Set("!#$%&'*+-.^_`|~".utf8)
    private enum State {
        case headers
        case fixed(Int)
        case chunkSize
        case chunk(Int)
        case trailers, complete
    }
    private var state = State.headers
    private var buffer = Data()
    private var body = Data()
    private var framingBytes = 0
    private var receivedBytes = 0
    private var status = 0
    private(set) var response: WebsiteIconHTTPResponse?

    mutating func append(_ data: Data) throws {
        guard response == nil else { throw WebsiteIconTransportError.invalidHTTP }
        guard data.count <= Self.bodyLimit - receivedBytes
        else { throw WebsiteIconTransportError.tooLarge }
        receivedBytes += data.count
        buffer.append(data)
        while response == nil {
            switch state {
            case .headers:
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    guard buffer.count <= Self.headerLimit else {
                        throw WebsiteIconTransportError.tooLarge
                    }
                    return
                }
                guard range.upperBound <= Self.headerLimit,
                    let header = String(data: buffer[..<range.lowerBound], encoding: .ascii)
                else { throw WebsiteIconTransportError.invalidHTTP }
                buffer = Data(buffer.dropFirst(range.upperBound))
                try parseHeaders(header)
            case .fixed(let remaining):
                let count = min(remaining, buffer.count)
                try collect(count)
                if count == remaining {
                    try finish()
                } else {
                    state = .fixed(remaining - count)
                    return
                }
            case .chunkSize:
                guard let line = try framingLine() else { return }
                guard !line.isEmpty, line.count <= 8,
                    line.utf8.allSatisfy({
                        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                    }),
                    let count = Int(line, radix: 16), count <= Self.bodyLimit - body.count
                else { throw WebsiteIconTransportError.invalidHTTP }
                state = count == 0 ? .trailers : .chunk(count)
            case .chunk(let count):
                guard buffer.count >= count + 2 else { return }
                guard buffer[count] == 13, buffer[count + 1] == 10 else {
                    throw WebsiteIconTransportError.invalidHTTP
                }
                try collect(count)
                buffer = Data(buffer.dropFirst(2))
                framingBytes += 2
                guard framingBytes <= Self.framingLimit else {
                    throw WebsiteIconTransportError.tooLarge
                }
                state = .chunkSize
            case .trailers:
                guard let line = try framingLine() else { return }
                guard line.isEmpty else { throw WebsiteIconTransportError.invalidHTTP }
                try finish()
            case .complete: return
            }
        }
    }

    mutating func end() throws -> WebsiteIconHTTPResponse {
        guard let response else { throw WebsiteIconTransportError.invalidHTTP }
        return response
    }

    private mutating func collect(_ count: Int) throws {
        guard count <= Self.bodyLimit - body.count else { throw WebsiteIconTransportError.tooLarge }
        body.append(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
    }

    private mutating func finish() throws {
        guard buffer.isEmpty else { throw WebsiteIconTransportError.invalidHTTP }
        state = .complete
        response = .init(status: status, body: body)
    }

    private mutating func framingLine() throws -> String? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else {
            guard buffer.count <= Self.framingLimit - framingBytes else {
                throw WebsiteIconTransportError.tooLarge
            }
            return nil
        }
        guard range.upperBound <= Self.framingLimit - framingBytes,
            let line = String(data: buffer[..<range.lowerBound], encoding: .ascii)
        else { throw WebsiteIconTransportError.invalidHTTP }
        framingBytes += range.upperBound
        buffer = Data(buffer.dropFirst(range.upperBound))
        return line
    }

    private mutating func parseHeaders(_ header: String) throws {
        let lines = header.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", maxSplits: 2)
        guard start.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(start[0]),
            start[1].count == 3, let code = Int(start[1]), (100...599).contains(code)
        else { throw WebsiteIconTransportError.invalidHTTP }
        status = code
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                !line.hasPrefix(" "), !line.hasPrefix("\t")
            else { throw WebsiteIconTransportError.invalidHTTP }
            let name = line[..<colon].lowercased()
            guard
                name.utf8.allSatisfy({
                    (97...122).contains($0) || (48...57).contains($0)
                        || Self.fieldNamePunctuation.contains($0)
                })
            else { throw WebsiteIconTransportError.invalidHTTP }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                throw WebsiteIconTransportError.invalidHTTP
            }
            if ["content-length", "transfer-encoding", "content-encoding"].contains(name) {
                guard fields[name] == nil else { throw WebsiteIconTransportError.invalidHTTP }
                fields[name] = value
            }
        }
        guard code == 200 else { throw WebsiteIconTransportError.status(code) }
        guard
            fields["content-encoding"] == nil
                || fields["content-encoding"]?.lowercased() == "identity"
        else { throw WebsiteIconTransportError.invalidHTTP }
        if let transfer = fields["transfer-encoding"] {
            guard start[0] == "HTTP/1.1", transfer.lowercased() == "chunked",
                fields["content-length"] == nil
            else { throw WebsiteIconTransportError.invalidHTTP }
            state = .chunkSize
        } else {
            guard let raw = fields["content-length"], !raw.isEmpty,
                raw.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(raw), count > 0
            else { throw WebsiteIconTransportError.invalidHTTP }
            guard count <= Self.bodyLimit else { throw WebsiteIconTransportError.tooLarge }
            state = .fixed(count)
        }
    }
}
