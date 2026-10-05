import CapdDesignSystem
import CapdMobile
import CapdSync
import CapdWebsiteIcons
import SwiftUI

struct WebsiteCaptureRow: View {
    private struct Request: Equatable, Hashable {
        let url: String?
        let generation: UUID?
        let library: UUID?
        let service: UUID?
        let revision: Int64
        let display: Bool
    }

    let capture: MobileCapture
    let metadata: String
    let icons: PhoneWebsiteIcons
    let scopeToken: MobileLibrarySessionToken?
    let iconRevision: Int64
    let readRecord: @Sendable (String, MobileLibrarySessionToken) async throws -> WebsiteIconRecord?
    let readData: @Sendable (WebsiteIconRecord, MobileLibrarySessionToken) async throws -> Data?
    @State private var record: WebsiteIconRecord?
    @State private var loadedRequest: Request?

    private var request: Request {
        .init(
            url: capture.kind == .link ? capture.url : nil,
            generation: scopeToken?.generation, library: scopeToken?.binding?.libraryID,
            service: scopeToken?.binding?.serviceID,
            revision: iconRevision, display: icons.displayEnabled)
    }

    private var identity: WebsiteIconIdentity? {
        guard loadedRequest == request, icons.displayEnabled, let token = scopeToken,
            let record, !record.deleted, let content = record.content
        else { return nil }
        return .init(
            library: token.binding.map { "\($0.serviceID.uuidString)/\($0.libraryID.uuidString)" }
                ?? "local", generation: token.generation,
            originID: record.id, revision: record.revision,
            normalizerVersion: content.normalizerVersion, digest: content.blob.digest)
    }

    private var load: WebsiteIconCache.Loader? {
        guard let record, let token = scopeToken else { return nil }
        let read = readData
        return { _ in try await read(record, token) }
    }

    var body: some View {
        let symbol = MobileCapturePresentation.symbol(for: capture)
        let tint: Color = capture.kind == .link ? .blue : capture.kind == .image ? .purple : .orange
        CapdSourceRow(
            title: capture.title, metadata: metadata, snippet: capture.selection,
            symbol: symbol, tint: tint, tags: capture.manualTags,
            status: capture.noteConflicts.isEmpty ? nil : "Notes to review"
        ) { size in
            WebsiteIconTile(
                identity: identity, cache: icons.cache, load: load,
                fallbackSymbol: symbol, fallbackTint: tint, size: size)
        }
        .task(id: request) {
            record = nil
            loadedRequest = nil
            guard request.display, let url = request.url, let token = scopeToken,
                let origin = WebsiteIconOrigin(url: url),
                let found = try? await readRecord(url, token), !Task.isCancelled,
                found.origin == origin, !found.deleted, (try? found.validate()) != nil
            else { return }
            record = found
            loadedRequest = request
        }
    }
}
