import CapdSync
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct WebsiteIconService: Sendable {
    private let store: Store
    private let fetch: @Sendable (WebsiteIconOrigin) async throws -> WebsiteIconFetchOutcome
    private let now: @Sendable () -> Date

    public init(
        store: Store,
        fetch: @escaping @Sendable (WebsiteIconOrigin) async throws -> WebsiteIconFetchOutcome,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.fetch = fetch
        self.now = now
    }

    public func processNext() async throws -> Bool {
        try Task.checkCancellation()
        guard let claim = try store.claimNextWebsiteIcon(now: now()) else { return false }
        let outcome: WebsiteIconFetchOutcome?
        do {
            outcome = try await fetch(claim.origin)
            try Task.checkCancellation()
            if case .normalizedPNG(let bytes) = outcome {
                try Self.validatePNG(bytes)
            }
        } catch {
            try finish(claim, outcome: nil)
            throw error
        }
        try finish(claim, outcome: outcome)
        return true
    }

    public func reclaimStale() throws -> Int { try store.reclaimStaleWebsiteIconClaims(now: now()) }

    public static func validatePNG(_ bytes: Data) throws {
        guard (1...262_144).contains(bytes.count),
            let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetType(source) as String? == UTType.png.identifier,
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            properties[kCGImagePropertyPixelWidth] as? Int == 64,
            properties[kCGImagePropertyPixelHeight] as? Int == 64,
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { throw SyncError.invalidBlob }
    }

    private func finish(_ claim: WebsiteIconClaim, outcome: WebsiteIconFetchOutcome?) throws {
        guard let lease = try MacSyncLease.acquire(paths: store.paths) else {
            throw MacSyncError.busy
        }
        defer { withExtendedLifetime(lease) {} }
        let configuration = try MacSyncConfiguration.load(paths: store.paths)
        guard configuration?.binding == claim.binding, configuration?.deviceID == claim.deviceID
        else { throw MacSyncError.configurationChanged }
        let content: WebsiteIconContent?
        var missing = false
        switch outcome {
        case .normalizedPNG(let bytes):
            guard (1...262_144).contains(bytes.count) else { throw SyncError.invalidBlob }
            let blobs =
                try store.syncClient?.blobs
                ?? BlobStore(
                    directory: store.paths.assetsDirectory.appendingPathComponent("website-icons"))
            content = WebsiteIconContent(
                blob: try blobs.put(bytes), normalizerVersion: claim.normalizerVersion,
                fetchedAt: now())
            try content?.validate()
        case .missing:
            missing = true
            content = nil
        case nil:
            content = nil
        }
        _ = try store.finishWebsiteIcon(claim, content: content, missing: missing, now: now())
    }
}
