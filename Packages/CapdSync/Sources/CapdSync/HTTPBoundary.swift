import Foundation

public struct SyncPrincipal: Codable, Equatable, Sendable {
    public let serviceID: UUID
    public let libraryID: UUID
    public let deviceID: UUID

    public init(serviceID: UUID, libraryID: UUID, deviceID: UUID) {
        self.serviceID = serviceID
        self.libraryID = libraryID
        self.deviceID = deviceID
    }
}

/// The host validates expiry/revocation and returns server-owned enrollment identities.
public protocol SyncAuthorizer: Sendable {
    func authorize(bearerCredential: String) throws -> SyncPrincipal?
}

public struct SyncHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct SyncHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum SyncHTTPAction: Codable, Sendable {
    case apply(SyncOperation)
    case changes(cursor: Int64, limit: Int)
    case baseline
    case baselinePage(after: UUID?, limit: Int, expectedCursor: Int64?)
    case upload(BlobReference, offset: Int, chunk: Data, final: Bool)
    case download(BlobReference)
}

public struct SyncHTTPEnvelope: Codable, Sendable {
    public let version: Int
    public let expectedServiceID: UUID
    public let expectedLibraryID: UUID
    public let expectedDeviceID: UUID
    public let action: SyncHTTPAction

    public init(
        version: Int = 1, expectedServiceID: UUID, expectedLibraryID: UUID, expectedDeviceID: UUID,
        action: SyncHTTPAction
    ) {
        self.version = version
        self.expectedServiceID = expectedServiceID
        self.expectedLibraryID = expectedLibraryID
        self.expectedDeviceID = expectedDeviceID
        self.action = action
    }
}

public enum SyncHTTPError: String, Error, Codable, Sendable {
    case notFound, methodNotAllowed, unauthorized, forbidden, unsupportedMediaType
    case malformedRequest, unsupportedVersion, requestTooLarge, resourceLimit, unavailable
    case invalidResponse
}

public enum SyncHTTPResult: Codable, Sendable {
    case receipt(SyncReceipt)
    case page(FeedPage)
    case baseline(Baseline)
    case data(Data)
    case okay
    case failure(SyncHTTPError)
    case domainFailure(SyncError)
}

public struct SyncHTTPReply: Codable, Sendable {
    public let version: Int
    public let principal: SyncPrincipal?
    public let result: SyncHTTPResult
    public let metadataContractVersion: Int?
    public let generatedProcessingContractVersion: Int?
    public let extractionQualityContractVersion: Int?

    public init(
        version: Int, principal: SyncPrincipal?, result: SyncHTTPResult,
        metadataContractVersion: Int? = nil, generatedProcessingContractVersion: Int? = nil,
        extractionQualityContractVersion: Int? = nil
    ) {
        self.version = version
        self.principal = principal
        self.result = result
        self.metadataContractVersion = metadataContractVersion
        self.generatedProcessingContractVersion = generatedProcessingContractVersion
        self.extractionQualityContractVersion = extractionQualityContractVersion
    }
}

/// Framework-neutral boundary; the host supplies HTTPS, admission limits and credential validation.
public struct SyncHTTPHandler: Sendable {
    public static let maximumBodyBytes = 16_777_216
    public static let maximumChunkBytes = 65_536
    public static let maximumPageSize = 1_000
    private let serviceID: UUID
    private let authorizer: any SyncAuthorizer
    private let server: @Sendable (UUID) throws -> SyncServer

    public init(
        serviceID: UUID, authorizer: any SyncAuthorizer,
        server: @escaping @Sendable (UUID) throws -> SyncServer
    ) {
        self.serviceID = serviceID
        self.authorizer = authorizer
        self.server = server
    }

    public func handle(_ request: SyncHTTPRequest) -> SyncHTTPResponse {
        guard request.path == "/v1/sync" else { return failure(.notFound, status: 404) }
        guard request.method == "POST" else { return failure(.methodNotAllowed, status: 405) }
        guard request.body.count <= Self.maximumBodyBytes else {
            return failure(.requestTooLarge, status: 413)
        }
        guard let credential = bearer(request.headers) else {
            return failure(.unauthorized, status: 401)
        }
        let principal: SyncPrincipal
        do {
            guard let authorized = try authorizer.authorize(bearerCredential: credential) else {
                return failure(.unauthorized, status: 401)
            }
            principal = authorized
        } catch { return failure(.unavailable, status: 503) }
        guard header("Content-Type", in: request.headers)?.lowercased() == "application/json" else {
            return failure(.unsupportedMediaType, status: 415)
        }
        let envelope: SyncHTTPEnvelope
        do { envelope = try SyncDatabase.decode(SyncHTTPEnvelope.self, request.body) } catch {
            return failure(.malformedRequest, status: 400)
        }
        guard (1...4).contains(envelope.version) else {
            return failure(.unsupportedVersion, status: 400)
        }
        guard principal.serviceID == serviceID, envelope.expectedServiceID == serviceID,
            envelope.expectedLibraryID == principal.libraryID,
            envelope.expectedDeviceID == principal.deviceID
        else {
            return failure(.forbidden, status: 403)
        }
        if case .apply(let operation) = envelope.action, operation.deviceID != principal.deviceID {
            return failure(.forbidden, status: 403)
        }
        if envelope.version < envelope.action.requiredEnvelopeVersion {
            return failure(.unsupportedVersion, status: 400)
        }
        if case .upload(_, _, let chunk, _) = envelope.action, chunk.count > Self.maximumChunkBytes
        {
            return failure(.requestTooLarge, status: 413)
        }
        if case .changes(_, let limit) = envelope.action,
            !(1...Self.maximumPageSize).contains(limit)
        {
            return domainFailure(.invalidCursor)
        }
        if case .baselinePage(_, let limit, _) = envelope.action,
            !(0...Self.maximumPageSize).contains(limit)
        {
            return domainFailure(.invalidCursor)
        }
        do {
            let authority = try server(principal.libraryID)
            guard authority.libraryID == principal.libraryID, authority.serviceID == serviceID
            else {
                return failure(.unavailable, status: 503)
            }
            let result: SyncHTTPResult
            switch envelope.action {
            case .apply(let operation):
                result = .receipt(
                    try authority.apply(operation) { receipt, change in
                        try checkResponseSize(.receipt(receipt), principal: principal)
                        if let change {
                            try checkResponseSize(
                                .page(FeedPage(cursor: change.cursor, changes: [change])),
                                principal: principal)
                        }
                    })
            case .changes(let cursor, let limit):
                result = .page(
                    try authority.changes(after: cursor, limit: limit) { pageCursor in
                        try SyncDatabase.encode(
                            replyPayload(
                                .page(FeedPage(cursor: pageCursor, changes: [])),
                                principal: principal)
                        ).count
                    })
            case .baseline:
                result = .baseline(
                    try authority.boundedBaseline { baselineCursor in
                        try baselineOverhead(cursor: baselineCursor, principal: principal)
                    })
            case .baselinePage(let after, let limit, let expectedCursor):
                result = .baseline(
                    try authority.boundedBaseline(
                        after: after, limit: limit, expectedCursor: expectedCursor
                    ) { baselineCursor in
                        try baselineOverhead(cursor: baselineCursor, principal: principal)
                    })
            case .upload(let blob, let offset, let chunk, let final):
                try authority.upload(blob, offset: offset, chunk: chunk, final: final)
                result = .okay
            case .download(let blob): result = .data(try authority.download(blob))
            }
            return reply(result, principal: principal, status: 200)
        } catch let error as SyncError { return domainFailure(error) } catch let error
            as SyncHTTPError
        {
            return failure(error, status: 503)
        } catch {
            return failure(.unavailable, status: 503)
        }
    }

    private func domainFailure(_ error: SyncError) -> SyncHTTPResponse {
        let status: Int
        switch error {
        case .cursorExpired, .operationIDReused, .outOfOrder: status = 409
        case .blobMissing: status = 404
        case .transportDisconnected, .acknowledgementLost: status = 503
        default: status = 422
        }
        return reply(.domainFailure(error), status: status)
    }

    private func failure(_ error: SyncHTTPError, status: Int) -> SyncHTTPResponse {
        reply(.failure(error), status: status)
    }

    private func baselineOverhead(cursor: Int64, principal: SyncPrincipal) throws -> Int {
        try SyncDatabase.encode(
            replyPayload(
                .baseline(Baseline(cursor: cursor, captures: [], deviceSequences: [:])),
                principal: principal)
        ).count
    }

    private func replyPayload(_ result: SyncHTTPResult, principal: SyncPrincipal?) -> SyncHTTPReply
    {
        SyncHTTPReply(
            version: 1, principal: principal, result: result,
            metadataContractVersion: principal == nil ? nil : 1,
            generatedProcessingContractVersion: principal == nil ? nil : 1,
            extractionQualityContractVersion: principal == nil ? nil : 1)
    }

    private func checkResponseSize(_ result: SyncHTTPResult, principal: SyncPrincipal) throws {
        guard
            try SyncDatabase.encode(replyPayload(result, principal: principal)).count
                <= Self.maximumBodyBytes
        else { throw SyncHTTPError.resourceLimit }
    }

    private func reply(_ result: SyncHTTPResult, principal: SyncPrincipal? = nil, status: Int)
        -> SyncHTTPResponse
    {
        let payload = replyPayload(result, principal: principal)
        if let body = try? SyncDatabase.encode(payload), body.count <= Self.maximumBodyBytes {
            var headers = ["Content-Type": "application/json", "Cache-Control": "no-store"]
            if status == 401 { headers["WWW-Authenticate"] = "Bearer" }
            if status == 405 { headers["Allow"] = "POST" }
            return SyncHTTPResponse(status: status, headers: headers, body: body)
        }
        // This constant fallback cannot contain storage errors, credentials or library content.
        return SyncHTTPResponse(
            status: 503,
            headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
            body: Data(#"{"version":1,"result":{"failure":{"_0":"resourceLimit"}}}"#.utf8))
    }
}

private func header(_ name: String, in headers: [String: String]) -> String? {
    let matches = headers.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }
    guard matches.count == 1 else { return nil }
    return matches.first?.value
}

private func bearer(_ headers: [String: String]) -> String? {
    guard let value = header("Authorization", in: headers), value.count <= 4_096 else { return nil }
    let parts = value.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].lowercased() == "bearer", !parts[1].isEmpty,
        parts[1].utf8.allSatisfy({ (33...126).contains($0) })
    else { return nil }
    return String(parts[1])
}

/// Local executor bridge, not a network client. Host/URL/redirect policy belongs to the future HTTPS adapter.
public struct SyncHTTPTransport: BoundSyncTransport {
    public let binding: SyncLibraryBinding
    public let deviceID: UUID
    private let credential: @Sendable () throws -> String
    private let execute: @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse

    public init(
        binding: SyncLibraryBinding, deviceID: UUID,
        credential: @escaping @Sendable () throws -> String,
        execute: @escaping @Sendable (SyncHTTPRequest) throws -> SyncHTTPResponse
    ) {
        self.binding = binding
        self.deviceID = deviceID
        self.credential = credential
        self.execute = execute
    }

    public func request(_ action: SyncHTTPAction) throws -> SyncHTTPResult {
        let version = action.requiredEnvelopeVersion
        if version > 1 {
            try requestReply(.baselinePage(after: nil, limit: 0, expectedCursor: nil))
                .checkCapabilities(for: action)
        }
        return try requestReply(action, version: version).result
    }

    private func requestReply(_ action: SyncHTTPAction, version: Int = 1) throws -> SyncHTTPReply {
        let token = try credential()
        let headers = ["Content-Type": "application/json", "Authorization": "Bearer \(token)"]
        guard bearer(headers) == token else { throw SyncHTTPError.unauthorized }
        let body = try SyncDatabase.encode(
            SyncHTTPEnvelope(
                version: version, expectedServiceID: binding.serviceID,
                expectedLibraryID: binding.libraryID,
                expectedDeviceID: deviceID, action: action))
        guard body.count <= SyncHTTPHandler.maximumBodyBytes else {
            throw SyncHTTPError.requestTooLarge
        }
        let response = try execute(
            SyncHTTPRequest(method: "POST", path: "/v1/sync", headers: headers, body: body))
        guard response.body.count <= SyncHTTPHandler.maximumBodyBytes,
            header("Content-Type", in: response.headers)?.lowercased() == "application/json",
            let reply = try? SyncDatabase.decode(SyncHTTPReply.self, response.body),
            reply.version == 1
        else { throw SyncHTTPError.invalidResponse }
        switch reply.result {
        case .failure(let error):
            guard response.status != 200, reply.principal == nil else {
                throw SyncHTTPError.invalidResponse
            }
            throw error
        case .domainFailure(let error):
            guard response.status != 200, reply.principal == nil else {
                throw SyncHTTPError.invalidResponse
            }
            throw error
        default:
            try reply.checkRequiredCapabilities(for: action)
            guard response.status == 200,
                reply.principal
                    == SyncPrincipal(
                        serviceID: binding.serviceID, libraryID: binding.libraryID,
                        deviceID: deviceID)
            else {
                throw SyncHTTPError.invalidResponse
            }
            return reply
        }
    }

    public func apply(_ operation: SyncOperation) throws -> SyncReceipt {
        guard operation.deviceID == deviceID else { throw SyncError.wrongDevice }
        guard case .receipt(let receipt) = try request(.apply(operation)) else {
            throw SyncHTTPError.invalidResponse
        }
        return receipt
    }
    public func changes(after cursor: Int64, limit: Int) throws -> FeedPage {
        guard case .page(let page) = try request(.changes(cursor: cursor, limit: limit)) else {
            throw SyncHTTPError.invalidResponse
        }
        return page
    }
    public func baseline() throws -> Baseline {
        var limit = 100
        var after: UUID?
        var first: Baseline?
        var captures: [SharedCapture] = []
        while true {
            try Task.checkCancellation()
            let result: SyncHTTPResult
            do {
                result = try request(
                    .baselinePage(after: after, limit: limit, expectedCursor: first?.cursor))
            } catch SyncHTTPError.resourceLimit where limit > 1 {
                limit = max(1, limit / 2)
                continue
            } catch SyncConnectionError.responseTooLarge where limit > 1 {
                limit = max(1, limit / 2)
                continue
            }
            guard case .baseline(let page) = result,
                page.captures.count <= limit,
                first == nil
                    || (page.cursor == first!.cursor
                        && page.deviceSequences == first!.deviceSequences),
                page.captures.allSatisfy({ after == nil || $0.id.uuidString > after!.uuidString }),
                zip(page.captures, page.captures.dropFirst()).allSatisfy({
                    $0.id.uuidString < $1.id.uuidString
                })
            else { throw SyncHTTPError.invalidResponse }
            if first == nil { first = page }
            captures.append(contentsOf: page.captures)
            if page.captures.count < limit {
                return Baseline(
                    cursor: page.cursor, captures: captures, deviceSequences: page.deviceSequences)
            }
            after = page.captures.last!.id
        }
    }
    public func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) throws {
        guard chunk.count <= SyncHTTPHandler.maximumChunkBytes else {
            throw SyncHTTPError.requestTooLarge
        }
        guard case .okay = try request(.upload(blob, offset: offset, chunk: chunk, final: final))
        else { throw SyncHTTPError.invalidResponse }
    }
    public func download(_ blob: BlobReference) throws -> Data {
        guard case .data(let data) = try request(.download(blob)) else {
            throw SyncHTTPError.invalidResponse
        }
        return data
    }
}
