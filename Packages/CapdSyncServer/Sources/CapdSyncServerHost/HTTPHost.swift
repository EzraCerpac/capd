import CapdMCP
import CapdSync
import Darwin
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import ServiceLifecycle

public enum HostHTTP {
    public static func mcpHeaders(_ fields: HTTPFields) -> [String: String]? {
        var result: [String: String] = [:]
        var bytes = 0
        let sensitive: Set<String> = [
            "authorization", "content-type", "accept", "origin", "mcp-protocol-version",
            "mcp-method", "mcp-name",
        ]
        for field in fields {
            let name = field.name.rawName.lowercased()
            bytes += name.utf8.count + field.value.utf8.count
            guard bytes <= 16_384 else { return nil }
            if sensitive.contains(name) {
                guard result[name] == nil else { return nil }
                result[name] = field.value
            }
        }
        return result
    }

    public static func mcpResponse(_ reply: MCPHTTPResponse) -> Response {
        response(SyncHTTPResponse(status: reply.status, headers: reply.headers, body: reply.body))
    }
    /// Preserve multiplicity until sensitive headers have been checked.
    public static func headers(_ fields: HTTPFields) -> [String: String]? {
        var result: [String: String] = [:]
        for field in fields {
            let name = field.name.rawName.lowercased()
            if name == "authorization" || name == "content-type" {
                guard result[name] == nil else { return nil }
                result[name] = field.value
            }
        }
        return result
    }

    public static func response(_ reply: SyncHTTPResponse) -> Response {
        var headers = HTTPFields()
        for (name, value) in reply.headers {
            if let field = HTTPField.Name(name) { headers[field] = value }
        }
        return Response(
            status: .init(code: reply.status), headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: reply.body)))
    }

    static func failure(_ reason: SyncHTTPError, status: Int) -> Response {
        let payload = "{\"version\":1,\"result\":{\"failure\":{\"_0\":\"\(reason.rawValue)\"}}}"
        var headers = ["Content-Type": "application/json", "Cache-Control": "no-store"]
        if status == 401 { headers["WWW-Authenticate"] = "Bearer" }
        return response(
            SyncHTTPResponse(status: status, headers: headers, body: Data(payload.utf8)))
    }

    static func bodyFailure(_ error: any Error) -> Response {
        if error is NIOTooManyBytesError { return failure(.requestTooLarge, status: 413) }
        return failure(.unavailable, status: 503)
    }

    public static func run(
        configurationURL: URL, dataDirectory: URL, port: Int,
        mcpConfigurationURL: URL? = nil, mcpSocketURL: URL? = nil
    ) async throws {
        guard (0...65_535).contains(port),
            (mcpConfigurationURL == nil) == (mcpSocketURL == nil)
        else { throw HostError.invalidArguments }
        if let mcpSocketURL { try MCPUnixSocket.validatePath(mcpSocketURL, mustExist: false) }
        let authority = try Authority(
            configurationURL: configurationURL, dataDirectory: dataDirectory,
            mcpConfigurationURL: mcpConfigurationURL)
        let admission = Admission()
        let router = Router()
        router.post("/v1/sync") { request, _ -> Response in
            guard let headers = headers(request.headers) else {
                return failure(.malformedRequest, status: 400)
            }
            guard await admission.acquire() else { return failure(.unavailable, status: 503) }
            let reply: Response
            do {
                let buffer = try await request.body.collect(upTo: SyncHTTPHandler.maximumBodyBytes)
                reply = response(
                    await authority.handle(
                        SyncHTTPRequest(
                            method: "POST", path: "/v1/sync", headers: headers,
                            body: Data(buffer.readableBytesView))))
            } catch {
                reply = bodyFailure(error)
            }
            await admission.release()
            return reply
        }
        let application = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port)),
            onServerRunning: { channel in
                if let boundPort = channel.localAddress?.port {
                    print("capd-sync-server ready 127.0.0.1:\(boundPort)")
                    fflush(stdout)
                }
            })
        guard mcpConfigurationURL != nil else {
            try await application.runService()
            return
        }
        // Preserve fail-closed startup for existing paths, but allow graceful restarts.
        defer {
            if let mcpSocketURL,
                (try? MCPUnixSocket.validatePath(mcpSocketURL, mustExist: true)) != nil
            {
                _ = unlink(mcpSocketURL.path)
            }
        }
        let mcpRouter = Router()
        mcpRouter.post("/mcp") { request, _ -> Response in
            let deadline = DispatchTime.now() + .seconds(5)
            guard let headers = mcpHeaders(request.headers) else {
                return mcpResponse(MCPWork.failure(400))
            }
            guard await admission.acquire() else { return mcpResponse(MCPWork.failure(503)) }
            let reply: Response
            do {
                let buffer = try await request.body.collect(upTo: 65_536)
                reply = mcpResponse(
                    await authority.handleMCP(
                        MCPHTTPRequest(
                            method: "POST", path: "/mcp", headers: headers,
                            body: Data(buffer.readableBytesView)), deadline: deadline))
            } catch {
                reply = mcpResponse(MCPWork.failure(error is NIOTooManyBytesError ? 413 : 503))
            }
            await admission.release()
            return reply
        }
        let mcpApplication = Application(
            router: mcpRouter,
            configuration: .init(address: .unixDomainSocket(path: mcpSocketURL!.path)),
            onServerRunning: { channel in
                guard (try? MCPUnixSocket.protectBoundSocket(mcpSocketURL!)) != nil else {
                    FileHandle.standardError.write(
                        Data("capd-mcp-bridge: socket protection failed\n".utf8))
                    exit(1)
                }
                print("capd-mcp-bridge ready private socket")
                fflush(stdout)
            })
        try await ServiceGroup(
            services: [application, mcpApplication],
            gracefulShutdownSignals: [.sigterm, .sigint], logger: application.logger
        ).run()
    }
}
