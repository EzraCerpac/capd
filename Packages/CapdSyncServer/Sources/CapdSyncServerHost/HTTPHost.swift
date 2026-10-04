import CapdSync
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

public enum HostHTTP {
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

    public static func run(configurationURL: URL, dataDirectory: URL, port: Int) async throws {
        let authority = try Authority(
            configurationURL: configurationURL, dataDirectory: dataDirectory)
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
        try await application.runService()
    }
}
