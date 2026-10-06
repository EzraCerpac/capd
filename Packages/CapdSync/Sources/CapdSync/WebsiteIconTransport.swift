import Foundation

extension SyncHTTPTransport {
    public func checkWebsiteIconCapability() throws {
        _ = try request(
            .websiteIconBaselinePage(
                after: nil, limit: 0, expectedCursor: nil, expectedCaptureCursor: nil))
    }

    public func applyWebsiteIcon(_ operation: WebsiteIconOperation) throws -> WebsiteIconReceipt {
        guard case .websiteIconReceipt(let receipt) = try request(.applyWebsiteIcon(operation))
        else { throw SyncHTTPError.invalidResponse }
        return receipt
    }

    public func websiteIconChanges(after cursor: Int64, limit: Int) throws -> WebsiteIconFeedPage {
        guard
            case .websiteIconPage(let page) = try request(
                .websiteIconChanges(cursor: cursor, limit: limit))
        else { throw SyncHTTPError.invalidResponse }
        return page
    }

    public func websiteIconBaseline() throws -> WebsiteIconBaseline {
        var records: [WebsiteIconRecord] = []
        var first: WebsiteIconBaseline?
        repeat {
            guard
                case .websiteIconBaseline(let page) = try request(
                    .websiteIconBaselinePage(
                        after: records.last?.id, limit: 100, expectedCursor: first?.cursor,
                        expectedCaptureCursor: first?.captureCursor))
            else { throw SyncHTTPError.invalidResponse }
            try WebsiteIconValidation.page(
                page, after: records.last?.id, first: first, accumulatedCount: records.count)
            if first == nil { first = page }
            records += page.records
            if records.count == page.totalIconCount { break }
            guard !page.records.isEmpty else { throw SyncHTTPError.invalidResponse }
        } while true
        return WebsiteIconBaseline(
            cursor: first!.cursor, captureCursor: first!.captureCursor, records: records,
            deviceSequences: first!.deviceSequences, totalIconCount: first!.totalIconCount)
    }

    public func uploadWebsiteIcon(_ blob: BlobReference, offset: Int, chunk: Data, final: Bool)
        throws
    {
        guard
            case .okay = try request(
                .uploadWebsiteIcon(blob, offset: offset, chunk: chunk, final: final))
        else { throw SyncHTTPError.invalidResponse }
    }

    public func downloadWebsiteIcon(_ blob: BlobReference) throws -> Data {
        guard case .data(let bytes) = try request(.downloadWebsiteIcon(blob)) else {
            throw SyncHTTPError.invalidResponse
        }
        guard BlobReference(data: bytes) == blob else { throw SyncError.invalidBlob }
        try WebsiteIconPNG.validate(bytes)
        return bytes
    }
}

extension AsyncSyncTransport {
    public func importWebsiteIconBaseline(
        expectedCaptureCursor: Int64? = nil, credential: @escaping @Sendable () throws -> String
    ) async throws -> WebsiteIconBaseline {
        try await AsyncHTTPActions(transport: self, credential: credential).websiteIconBaseline(
            expectedCaptureCursor: expectedCaptureCursor)
    }

    public func importWebsiteIconData(
        _ blob: BlobReference, credential: @escaping @Sendable () throws -> String
    ) async throws -> Data {
        guard
            case .data(let bytes) = try await AsyncHTTPActions(
                transport: self, credential: credential
            ).request(.downloadWebsiteIcon(blob))
        else { throw SyncHTTPError.invalidResponse }
        guard BlobReference(data: bytes) == blob else { throw SyncError.invalidBlob }
        try WebsiteIconPNG.validate(bytes)
        return bytes
    }
}

extension AsyncHTTPActions {
    func websiteIconBaseline(expectedCaptureCursor: Int64? = nil) async throws
        -> WebsiteIconBaseline
    {
        var records: [WebsiteIconRecord] = []
        var first: WebsiteIconBaseline?
        repeat {
            guard
                case .websiteIconBaseline(let page) = try await request(
                    .websiteIconBaselinePage(
                        after: records.last?.id, limit: 100, expectedCursor: first?.cursor,
                        expectedCaptureCursor: first?.captureCursor ?? expectedCaptureCursor))
            else { throw SyncHTTPError.invalidResponse }
            try WebsiteIconValidation.page(
                page, after: records.last?.id, first: first, accumulatedCount: records.count)
            guard expectedCaptureCursor == nil || page.captureCursor == expectedCaptureCursor else {
                throw SyncError.invalidCursor
            }
            if first == nil { first = page }
            records += page.records
            if records.count == page.totalIconCount { break }
            guard !page.records.isEmpty else { throw SyncHTTPError.invalidResponse }
        } while true
        return WebsiteIconBaseline(
            cursor: first!.cursor, captureCursor: first!.captureCursor, records: records,
            deviceSequences: first!.deviceSequences, totalIconCount: first!.totalIconCount)
    }
}

enum WebsiteIconValidation {
    static func page(
        _ page: WebsiteIconBaseline, after: String?, first: WebsiteIconBaseline?,
        accumulatedCount: Int
    )
        throws
    {
        guard page.cursor >= 0, page.captureCursor >= 0, page.totalIconCount >= 0,
            page.totalIconCount <= 4096, accumulatedCount >= 0,
            accumulatedCount <= page.totalIconCount,
            page.records.count == min(100, page.totalIconCount - accumulatedCount),
            page.deviceSequences.count <= 4096,
            page.deviceSequences.values.allSatisfy({ $0 >= 0 }),
            first == nil
                || (first!.cursor == page.cursor && first!.captureCursor == page.captureCursor
                    && first!.totalIconCount == page.totalIconCount
                    && first!.deviceSequences == page.deviceSequences)
        else { throw SyncError.invalidCursor }
        var last = after ?? ""
        for record in page.records {
            try record.validate()
            guard record.revision > 0, record.revision <= page.cursor, record.id > last else {
                throw SyncError.invalidCursor
            }
            last = record.id
        }
    }
}
