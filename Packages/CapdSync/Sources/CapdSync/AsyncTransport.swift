import Foundation

/// An authenticated wire executor pinned to one enrolled library and device.
public protocol AsyncSyncTransport: Sendable {
    var binding: SyncLibraryBinding { get }
    var deviceID: UUID { get }
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse
}

extension AsyncSyncTransport {
    /// Fetches an authenticated baseline with the capabilities required before initial import.
    public func importBaseline(
        credential: @escaping @Sendable () throws -> String,
        requiringGeneratedProcessingContract: Bool = false,
        requiringExtractionQualityContract: Bool = false, summaryOnly: Bool = false
    ) async throws -> Baseline {
        try await AsyncHTTPActions(transport: self, credential: credential)
            .baseline(
                requiringMetadataContract: true,
                requiringGeneratedProcessingContract: requiringGeneratedProcessingContract,
                requiringExtractionQualityContract: requiringExtractionQualityContract,
                summaryOnly: summaryOnly)
    }
}

public enum SyncConnectionError: Error, Equatable, Sendable {
    case invalidEndpoint, redirectRefused, responseTooLarge, secureConnectionFailed
    case credentialUnavailable, invalidCredential, enrollmentDisabled
}

extension SyncConnectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid HTTPS sync address."
        case .redirectRefused: "The sync address redirected. Check the enrolled address."
        case .responseTooLarge:
            "The server response exceeded the sync limit. Your changes remain saved."
        case .secureConnectionFailed: "A secure connection could not be verified."
        case .credentialUnavailable: "The device credential is unavailable. Check device setup."
        case .invalidCredential: "The device credential is invalid."
        case .enrollmentDisabled:
            "Device connection is unavailable until library migration is ready."
        }
    }
}

extension SyncHTTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized: "The device credential expired or was revoked. Check device setup."
        case .forbidden: "This device is not authorized for the enrolled library."
        case .unavailable: "The sync service is temporarily unavailable. Your changes remain saved."
        default:
            "The sync server returned an invalid or unsupported response. Your changes remain saved."
        }
    }
}

struct AsyncHTTPActions {
    let transport: any AsyncSyncTransport
    let credential: @Sendable () throws -> String

    func request(_ action: SyncHTTPAction) async throws -> SyncHTTPResult {
        let version = action.requiredEnvelopeVersion
        if version > 1 {
            try await requestReply(.baselinePage(after: nil, limit: 0, expectedCursor: nil))
                .checkCapabilities(for: action)
        }
        return try await requestReply(action, version: version).result
    }

    private func requestReply(_ action: SyncHTTPAction, version: Int = 1) async throws
        -> SyncHTTPReply
    {
        try Task.checkCancellation()
        let token = try credential()
        try SyncCredentialValidation.check(token)
        let body = try SyncDatabase.encode(
            SyncHTTPEnvelope(
                version: version, expectedServiceID: transport.binding.serviceID,
                expectedLibraryID: transport.binding.libraryID,
                expectedDeviceID: transport.deviceID, action: action))
        guard body.count <= SyncHTTPHandler.maximumBodyBytes else {
            throw SyncHTTPError.requestTooLarge
        }
        let response = try await transport.send(
            SyncHTTPRequest(
                method: "POST", path: "/v1/sync",
                headers: ["Content-Type": "application/json", "Authorization": "Bearer \(token)"],
                body: body))
        try Task.checkCancellation()
        if response.status == 401 { throw SyncHTTPError.unauthorized }
        if response.status == 403 { throw SyncHTTPError.forbidden }
        guard response.body.count <= SyncHTTPHandler.maximumBodyBytes,
            response.headers.filter({ $0.key.lowercased() == "content-type" }).count == 1,
            response.headers.first(where: { $0.key.lowercased() == "content-type" })?.value
                .split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
                == "application/json",
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
                        serviceID: transport.binding.serviceID,
                        libraryID: transport.binding.libraryID, deviceID: transport.deviceID)
            else { throw SyncHTTPError.invalidResponse }
            return reply
        }
    }

    func apply(_ operation: SyncOperation) async throws -> SyncReceipt {
        guard operation.deviceID == transport.deviceID else { throw SyncError.wrongDevice }
        guard case .receipt(let receipt) = try await request(.apply(operation)) else {
            throw SyncHTTPError.invalidResponse
        }
        return receipt
    }

    func changes(after cursor: Int64, limit requestedLimit: Int) async throws -> FeedPage {
        var limit = requestedLimit
        while true {
            do {
                guard
                    case .page(let page) = try await request(.changes(cursor: cursor, limit: limit))
                else { throw SyncHTTPError.invalidResponse }
                return page
            } catch SyncHTTPError.resourceLimit where limit > 1 {
                limit = max(1, limit / 2)
            } catch SyncConnectionError.responseTooLarge where limit > 1 {
                limit = max(1, limit / 2)
            }
        }
    }

    func baseline(
        requiringMetadataContract: Bool = false,
        requiringGeneratedProcessingContract: Bool = false,
        requiringExtractionQualityContract: Bool = false, summaryOnly: Bool = false
    ) async throws -> Baseline {
        var limit = summaryOnly ? 0 : 100
        var after: UUID?
        var first: Baseline?
        var captures: [SharedCapture] = []
        while true {
            let reply: SyncHTTPReply
            do {
                reply = try await requestReply(
                    .baselinePage(
                        after: after, limit: limit, expectedCursor: first?.cursor))
            } catch SyncHTTPError.resourceLimit where limit > 1 {
                limit = max(1, limit / 2)
                continue
            } catch SyncConnectionError.responseTooLarge where limit > 1 {
                limit = max(1, limit / 2)
                continue
            }
            guard case .baseline(let page) = reply.result else {
                throw SyncHTTPError.invalidResponse
            }
            guard
                !(requiringMetadataContract || requiringGeneratedProcessingContract
                    || requiringExtractionQualityContract)
                    || reply.metadataContractVersion == 1,
                !requiringGeneratedProcessingContract
                    || reply.generatedProcessingContractVersion == 1,
                !requiringExtractionQualityContract || reply.extractionQualityContractVersion == 1
            else { throw SyncHTTPError.unsupportedVersion }
            guard page.captures.count <= limit,
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
            if summaryOnly || page.captures.count < limit {
                return Baseline(
                    cursor: page.cursor, captures: captures, deviceSequences: page.deviceSequences)
            }
            after = page.captures.last!.id
        }
    }

    func upload(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool) async throws {
        guard chunk.count <= SyncHTTPHandler.maximumChunkBytes else {
            throw SyncHTTPError.requestTooLarge
        }
        guard
            case .okay = try await request(
                .upload(blob, offset: offset, chunk: chunk, final: final))
        else { throw SyncHTTPError.invalidResponse }
    }

    func download(_ blob: BlobReference) async throws -> Data {
        guard case .data(let data) = try await request(.download(blob)) else {
            throw SyncHTTPError.invalidResponse
        }
        return data
    }
}
