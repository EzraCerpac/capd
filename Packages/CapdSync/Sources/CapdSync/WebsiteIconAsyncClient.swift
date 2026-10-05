import Foundation

extension SyncClient {
    public func pushWebsiteIcons(
        to transport: any AsyncSyncTransport, credential: @escaping @Sendable () throws -> String
    ) async throws {
        guard let binding, transport.binding == binding, transport.deviceID == deviceID else {
            throw SyncBindingError.mismatch
        }
        let actions = AsyncHTTPActions(transport: transport, credential: credential)
        _ = try await actions.request(
            .websiteIconBaselinePage(
                after: nil, limit: 0, expectedCursor: nil, expectedCaptureCursor: nil))
        for operation in try pendingWebsiteIconOperations() {
            if case .upsert(let content) = operation.mutation {
                let bytes = try blobs.read(content.blob)
                try WebsiteIconPNG.validate(bytes)
                for offset in stride(
                    from: 0, to: bytes.count, by: SyncHTTPHandler.maximumChunkBytes)
                {
                    let end = min(bytes.count, offset + SyncHTTPHandler.maximumChunkBytes)
                    guard
                        case .okay = try await actions.request(
                            .uploadWebsiteIcon(
                                content.blob, offset: offset,
                                chunk: bytes.subdata(in: offset..<end), final: end == bytes.count))
                    else { throw SyncHTTPError.invalidResponse }
                }
            }
            guard
                case .websiteIconReceipt(let receipt) = try await actions.request(
                    .applyWebsiteIcon(operation))
            else { throw SyncHTTPError.invalidResponse }
            try validateWebsiteIconReceipt(receipt, operation: operation)
            try await cacheWebsiteIconAsync(
                receipt.record, transport: transport, credential: credential)
            try Task.checkCancellation()
            try acknowledgeWebsiteIcon(receipt, operation: operation)
        }
    }

    func cacheWebsiteIconAsync(
        _ record: WebsiteIconRecord?, transport: any AsyncSyncTransport,
        credential: @escaping @Sendable () throws -> String
    ) async throws {
        guard let content = record?.content else { return }
        if let bytes = try? blobs.read(content.blob) {
            try WebsiteIconPNG.validate(bytes)
            return
        }
        let bytes = try await transport.importWebsiteIconData(content.blob, credential: credential)
        try Task.checkCancellation()
        _ = try blobs.put(bytes)
    }

    public func pullWebsiteIcons(
        from transport: any AsyncSyncTransport, credential: @escaping @Sendable () throws -> String,
        pageSize: Int = 100
    ) async throws {
        guard let binding, transport.binding == binding, transport.deviceID == deviceID else {
            throw SyncBindingError.mismatch
        }
        let actions = AsyncHTTPActions(transport: transport, credential: credential)
        _ = try await actions.request(
            .websiteIconBaselinePage(
                after: nil, limit: 0, expectedCursor: nil, expectedCaptureCursor: nil))
        do {
            while true {
                let cursor = try websiteIconCursor()
                guard
                    case .websiteIconPage(let page) = try await actions.request(
                        .websiteIconChanges(cursor: cursor, limit: pageSize))
                else { throw SyncHTTPError.invalidResponse }
                try validateWebsiteIconPage(page, cursor: cursor)
                for change in page.changes {
                    try await cacheWebsiteIconAsync(
                        change.record, transport: transport, credential: credential)
                }
                try Task.checkCancellation()
                try commitWebsiteIconPage(page, cursor: cursor)
                if page.changes.isEmpty { return }
            }
        } catch SyncError.cursorExpired {
            let baseline = try await actions.websiteIconBaseline()
            try read { try validateWebsiteIconBaseline(baseline, in: $0) }
            for record in baseline.records {
                try await cacheWebsiteIconAsync(
                    record, transport: transport, credential: credential)
            }
            try Task.checkCancellation()
            try commitWebsiteIconBaseline(baseline)
        }
    }
}
