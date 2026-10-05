import CapdSync
import Foundation

let arguments = CommandLine.arguments
func argument(_ name: String) throws -> String {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        throw SyncError.invalidOperation
    }
    return arguments[index + 1]
}

func pullAll(_ client: SyncClient, from transport: any SyncTransport) throws {
    for _ in 0..<100 {
        let cursor = try client.cursor()
        try client.pull(from: transport)
        if try client.cursor() == cursor { return }
    }
    throw SyncError.invalidCursor
}

let root = URL(fileURLWithPath: try argument("--synthetic-root"), isDirectory: true)
let portFile = URL(fileURLWithPath: try argument("--port-file"))
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let listener = try ReferenceListener()
let handle: (ReferenceRequest) throws -> ReferenceResponse?
if arguments.contains("--authority") {
    let server = try SyncServer(
        databaseURL: root.appendingPathComponent("authority.sqlite"),
        blobDirectory: root.appendingPathComponent("blobs"))
    var unavailable = false
    var dropNext = false
    handle = { request in
        switch request {
        case .unavailable(let value):
            unavailable = value
            return .okay
        case .dropNextAcknowledgement:
            dropNext = true
            return .okay
        default: break
        }
        if unavailable { return nil }
        switch request {
        case .apply(let operation):
            let receipt = try server.apply(operation)
            if dropNext {
                dropNext = false
                return nil
            }
            return .receipt(receipt)
        case .changes(let cursor, let limit):
            return .page(try server.changes(after: cursor, limit: limit))
        case .baseline: return .baseline(try server.baseline())
        case .upload(let blob, let offset, let chunk, let final):
            try server.upload(blob, offset: offset, chunk: chunk, final: final)
            return .okay
        case .download(let blob): return .data(try server.download(blob))
        default: throw SyncError.invalidOperation
        }
    }
} else if arguments.contains("--mac-client"),
    let port = UInt16(try argument("--authority-port")), port > 0
{
    let deviceFile = root.appendingPathComponent("device-id")
    let device: UUID
    if FileManager.default.fileExists(atPath: deviceFile.path) {
        guard let stored = UUID(uuidString: try String(contentsOf: deviceFile, encoding: .utf8))
        else {
            throw SyncError.wrongDevice
        }
        device = stored
    } else {
        device = UUID()
        try device.uuidString.write(to: deviceFile, atomically: true, encoding: .utf8)
    }
    let client = try SyncClient(
        databaseURL: root.appendingPathComponent("mac.sqlite"),
        blobDirectory: root.appendingPathComponent("blobs"), deviceID: device)
    let transport = ReferenceTransport(port: port)
    handle = { request in
        switch request {
        case .fixtureCreate(let capture):
            try client.enqueue(captureID: capture.id, mutation: .create(capture))
        case .fixtureEdit(let id, let edit):
            try client.enqueue(captureID: id, mutation: .edit(edit))
        case .fixtureDelete(let id): try client.enqueue(captureID: id, mutation: .delete)
        case .fixtureSync:
            try pullAll(client, from: transport)
            try client.push(to: transport)
            try pullAll(client, from: transport)
        case .fixturePull: try pullAll(client, from: transport)
        case .fixtureCaptures: return .captures(try client.captures(includeDeleted: true))
        case .fixturePending: return .operations(try client.pendingOperations())
        default: throw SyncError.invalidOperation
        }
        return .okay
    }
} else {
    throw SyncError.invalidOperation
}
try String(listener.port).write(to: portFile, atomically: true, encoding: .utf8)
print("Synthetic reference process listening on 127.0.0.1:\(listener.port)")
try listener.run(handle: handle)
