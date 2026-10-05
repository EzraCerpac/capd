import Foundation

enum SyncEndpointPolicy: Sendable {
    case https, syntheticLoopback

    static func validate(_ endpoint: URL, policy: Self = .https) throws {
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path == "/v1/sync",
            components.port.map({ (1...65_535).contains($0) }) ?? true
        else { throw SyncConnectionError.invalidEndpoint }
        switch policy {
        case .https:
            guard components.scheme?.lowercased() == "https" else {
                throw SyncConnectionError.invalidEndpoint
            }
        case .syntheticLoopback:
            guard components.scheme?.lowercased() == "http",
                host == "127.0.0.1" || host == "[::1]" || host == "::1"
            else { throw SyncConnectionError.invalidEndpoint }
        }
    }
}

/// Each request owns an ephemeral session; cancellation invalidates that session immediately.
public struct URLSessionSyncTransport: AsyncSyncTransport {
    public let binding: SyncLibraryBinding
    public let deviceID: UUID
    public let endpoint: URL
    private let maximumResponseBytes: Int
    private let timeout: TimeInterval
    private let loopbackSOCKSPort: Int?

    public init(
        endpoint: URL, binding: SyncLibraryBinding, deviceID: UUID,
        maximumResponseBytes: Int = SyncHTTPHandler.maximumBodyBytes,
        timeout: TimeInterval = 30, loopbackSOCKSPort: Int? = nil
    ) throws {
        try self.init(
            endpoint: endpoint, binding: binding, deviceID: deviceID, policy: .https,
            maximumResponseBytes: maximumResponseBytes, timeout: timeout,
            loopbackSOCKSPort: loopbackSOCKSPort)
    }

    init(
        endpoint: URL, binding: SyncLibraryBinding, deviceID: UUID,
        policy: SyncEndpointPolicy,
        maximumResponseBytes: Int = SyncHTTPHandler.maximumBodyBytes,
        timeout: TimeInterval = 30, loopbackSOCKSPort: Int? = nil
    ) throws {
        try SyncEndpointPolicy.validate(endpoint, policy: policy)
        guard (1...SyncHTTPHandler.maximumBodyBytes).contains(maximumResponseBytes),
            timeout.isFinite, timeout > 0, timeout <= 300,
            loopbackSOCKSPort.map({ (1...65_535).contains($0) }) ?? true
        else { throw SyncConnectionError.invalidEndpoint }
        self.endpoint = endpoint
        self.binding = binding
        self.deviceID = deviceID
        self.maximumResponseBytes = maximumResponseBytes
        self.timeout = timeout
        self.loopbackSOCKSPort = loopbackSOCKSPort
    }

    public func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        try Task.checkCancellation()
        guard request.method == "POST", request.path == "/v1/sync" else {
            throw SyncHTTPError.malformedRequest
        }
        guard request.body.count <= SyncHTTPHandler.maximumBodyBytes else {
            throw SyncHTTPError.requestTooLarge
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.allHTTPHeaderFields = request.headers
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let exchange = BoundedHTTPExchange(
            limit: maximumResponseBytes, timeout: timeout, loopbackSOCKSPort: loopbackSOCKSPort)
        return try await exchange.perform(urlRequest)
    }
}

private final class BoundedHTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let timeout: TimeInterval
    private let loopbackSOCKSPort: Int?
    private var cancelled = false
    private var continuation: CheckedContinuation<SyncHTTPResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()

    init(limit: Int, timeout: TimeInterval, loopbackSOCKSPort: Int?) {
        self.limit = limit
        self.timeout = timeout
        self.loopbackSOCKSPort = loopbackSOCKSPort
    }

    func perform(_ request: URLRequest) async throws -> SyncHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                if let loopbackSOCKSPort {
                    configuration.connectionProxyDictionary = [
                        "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": loopbackSOCKSPort,
                    ]
                }
                configuration.urlCache = nil
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = timeout
                configuration.timeoutIntervalForResource = timeout
                let session = URLSession(
                    configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<SyncHTTPResponse, any Error>) {
        let completion = lock.withLock {
            () -> (CheckedContinuation<SyncHTTPResponse, any Error>?, URLSession?) in
            let completion = (continuation, session)
            continuation = nil
            session = nil
            task = nil
            return completion
        }
        completion.1?.invalidateAndCancel()
        completion.0?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(SyncConnectionError.redirectRefused))
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(SyncHTTPError.invalidResponse))
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel)
            finish(.failure(SyncConnectionError.responseTooLarge))
            return
        }
        lock.withLock { self.response = response }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock {
            guard continuation != nil else { return false }
            guard data.count <= limit - body.count else { return true }
            body.append(data)
            return false
        }
        if overflow { finish(.failure(SyncConnectionError.responseTooLarge)) }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        if let error {
            let mapped: any Error
            switch (error as? URLError)?.code {
            case .cancelled: mapped = CancellationError()
            case .serverCertificateHasBadDate, .serverCertificateUntrusted,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
                mapped = SyncConnectionError.secureConnectionFailed
            default: mapped = SyncError.transportDisconnected
            }
            finish(.failure(mapped))
            return
        }
        let result: Result<SyncHTTPResponse, any Error> = lock.withLock {
            guard let response else { return .failure(SyncHTTPError.invalidResponse) }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            return .success(
                SyncHTTPResponse(status: response.statusCode, headers: headers, body: body))
        }
        finish(result)
    }
}
