import CapdMCP
import CapdSync
import Foundation

/// Queued work is cancelled before storage access. Running work can finish after the response
/// deadline; its outcome is deliberately uncertain, so writes must retry their exact identity.
final class MCPWork: @unchecked Sendable {
    let deadline: DispatchTime
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var delivered: MCPHTTPResponse?
    private var continuation: CheckedContinuation<MCPHTTPResponse, Never>?
    init(deadline: DispatchTime) { self.deadline = deadline }
    func install(_ value: CheckedContinuation<MCPHTTPResponse, Never>) {
        lock.lock()
        if let reply = delivered {
            lock.unlock()
            value.resume(returning: reply)
        } else {
            continuation = value
            lock.unlock()
        }
    }
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, delivered == nil,
            DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds
        else { return false }
        started = true
        return true
    }
    func mayExecute() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && !finished && delivered == nil
            && DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds
    }
    func expire() {
        lock.lock()
        guard delivered == nil else {
            lock.unlock()
            return
        }
        let reply = Self.failure(
            504,
            started
                ? "Outcome may be unknown; retry identical operation_id, sequence and arguments without renumbering"
                : "Request expired before execution; retry identical arguments without renumbering")
        delivered = reply
        let next = continuation
        continuation = nil
        lock.unlock()
        next?.resume(returning: reply)
    }
    func complete(_ reply: MCPHTTPResponse, final: Bool = true) {
        lock.lock()
        if final { finished = true }
        guard delivered == nil else {
            lock.unlock()
            return
        }
        let output =
            final && DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds
            ? Self.failure(
                504,
                started
                    ? "Outcome may be unknown; retry identical operation_id, sequence and arguments without renumbering"
                    : "Request expired before execution; retry identical arguments without renumbering"
            ) : reply
        delivered = output
        let next = continuation
        continuation = nil
        lock.unlock()
        next?.resume(returning: output)
    }
    static func failure(_ status: Int, _ message: String = "CAPD bridge request refused")
        -> MCPHTTPResponse
    {
        // Transport shim wraps this safe text in the original JSON-RPC identity.
        MCPHTTPResponse(
            status: status,
            headers: ["Cache-Control": "no-store", "Content-Type": "application/json"],
            body: (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data())
    }
}

final class MCPQueueLimit: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active < 8 else { return false }
        active += 1
        return true
    }
    func release() {
        lock.lock()
        active -= 1
        lock.unlock()
    }
}

extension Authority {
    public func handleMCP(_ request: MCPHTTPRequest, deadline: DispatchTime = .now() + .seconds(5))
        async -> MCPHTTPResponse
    {
        guard mcpConfigurationURL != nil else { return MCPWork.failure(404) }
        guard request.body.count <= 65_536 else { return MCPWork.failure(413) }
        guard request.headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 16_384
        else { return MCPWork.failure(431) }
        guard mcpQueueLimit.acquire() else { return MCPWork.failure(503) }
        let work = MCPWork(deadline: deadline)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                work.install(continuation)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { work.expire() }
                queue.async { [self] in
                    defer { mcpQueueLimit.release() }
                    guard work.begin() else {
                        work.expire()
                        return
                    }
                    work.complete(processMCP(request, work: work))
                }
            }
        } onCancel: {
            work.expire()
        }
    }

    private func processMCP(_ request: MCPHTTPRequest, work: MCPWork) -> MCPHTTPResponse {
        guard request.path == "/mcp" else { return MCPWork.failure(404) }
        guard request.method == "POST" else { return MCPWork.failure(405) }
        var headers: [String: String] = [:]
        for (key, value) in request.headers {
            guard headers[key.lowercased()] == nil else { return MCPWork.failure(400) }
            headers[key.lowercased()] = value
        }
        guard headers["origin"] == nil, let authorization = headers["authorization"],
            authorization.hasPrefix("Bearer "), authorization.utf8.count == 71,
            let policyURL = mcpConfigurationURL
        else { return MCPWork.failure(401) }
        let bearer = String(authorization.dropFirst(7))
        do {
            // Intentionally AFTER queue admission and BEFORE opening capture storage.
            let policy = try MCPBridgeConfiguration.read(policyURL)
            let sync = try HostConfiguration.read(authorizer.configurationURL)
            guard let grant = try policy.authorize(bearer, serviceID: serviceID, sync: sync) else {
                return MCPWork.failure(401)
            }
            guard work.mayExecute() else {
                return MCPWork.failure(
                    504,
                    "Request expired before execution; retry identical arguments without renumbering"
                )
            }
            // Reject unsafe SQLite paths before GRDB opens the read-only store.
            try validateExistingLibrary(grant.binding.libraryID)
            let store = try AcceptedStore(
                databaseURL: libraryRoot(grant.binding.libraryID).appendingPathComponent(
                    "authority.sqlite"), binding: grant.binding)
            let server = try server(for: grant.binding.libraryID, requireExisting: true)
            let toolbox = try MCPToolbox(store: store, authority: server)
            let boundary = try MCPHTTPBoundary(
                bridgeToolbox: toolbox,
                verifier: MCPBridgeRequestVerifier(bearer: bearer, grant: grant),
                resource: policy.resource, binding: grant.binding)
            return boundary.handle(request, mayExecute: { work.mayExecute() })
        } catch { return MCPWork.failure(503) }
    }
}
