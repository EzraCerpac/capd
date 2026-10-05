import AppKit
import CapdKit
import CapdSync
import CapdWebsiteIcons
import Observation
import SwiftUI

package struct Favicon {
    package var image: NSImage
    package var needsLightBacking: Bool
}

@MainActor
@Observable
package final class FaviconStore {
    private let scope: String
    private let generation: UUID
    private let read: @Sendable (WebsiteIconRecord) async throws -> Data?
    private let cache = WebsiteIconCache()
    private var records: [String: WebsiteIconRecord] = [:]
    private var icons: [WebsiteIconIdentity: Favicon] = [:]
    @ObservationIgnored private var resolved: Set<WebsiteIconIdentity> = []
    @ObservationIgnored private var tasks:
        [WebsiteIconIdentity: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var uses: [WebsiteIconIdentity: UInt64] = [:]
    @ObservationIgnored private var tick: UInt64 = 0

    package convenience init(store: Store, scope: String, generation: UUID = UUID()) {
        self.init(scope: scope, generation: generation) { record in
            try await Task.detached(priority: .utility) {
                try store.verifiedWebsiteIconData(record)
            }.value
        }
        observation = Task { [weak self] in
            do {
                for try await records in store.websiteIconRecords() {
                    guard !Task.isCancelled else { return }
                    self?.replaceRecords(records)
                }
            } catch {
                self?.replaceRecords([])
            }
        }
    }

    package init(
        scope: String, generation: UUID = UUID(), records: [WebsiteIconRecord] = [],
        read: @escaping @Sendable (WebsiteIconRecord) async throws -> Data?
    ) {
        self.scope = scope
        self.generation = generation
        self.read = read
        replaceRecords(records)
    }

    func favicon(forURL url: String) -> Favicon? {
        guard let origin = WebsiteIconOrigin(url: url), let record = records[origin.id],
            let identity = identity(record)
        else { return nil }
        if let image = icons[identity] {
            tick &+= 1
            uses[identity] = tick
            return image
        }
        guard !resolved.contains(identity), tasks[identity] == nil, tasks.count < 16 else {
            return nil
        }
        let read = read
        let attempt = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.tasks[identity]?.id == attempt { self.tasks[identity] = nil }
            }
            let loaded = await self.cache.image(for: identity) { _ in try await read(record) }
            guard !Task.isCancelled, self.identity(self.records[record.id]) == identity else {
                return
            }
            self.resolved.insert(identity)
            guard let loaded else { return }
            let needsLightBacking = await Task.detached(priority: .utility) {
                FaviconLuminance.needsLightBacking(loaded.image)
            }.value
            guard !Task.isCancelled, self.identity(self.records[record.id]) == identity else {
                return
            }
            self.icons[identity] = Favicon(
                image: NSImage(
                    cgImage: loaded.image,
                    size: NSSize(
                        width: CGFloat(loaded.image.width), height: CGFloat(loaded.image.height))),
                needsLightBacking: needsLightBacking)
            self.tick &+= 1
            self.uses[identity] = self.tick
            if self.icons.count > 128,
                let oldest = self.uses.min(by: { $0.value < $1.value })?.key
            {
                self.icons[oldest] = nil
                self.uses[oldest] = nil
                self.resolved.remove(oldest)
            }
        }
        tasks[identity] = (attempt, task)
        return nil
    }

    func replaceRecords(_ values: [WebsiteIconRecord]) {
        var next: [String: WebsiteIconRecord] = [:]
        for record in values where !record.deleted && (try? record.validate()) != nil {
            next[record.id] = record
        }
        records = next
        let current = Set(next.values.compactMap(identity))
        icons = icons.filter { current.contains($0.key) }
        uses = uses.filter { current.contains($0.key) }
        resolved = Set(icons.keys)
        for (identity, running) in tasks where !current.contains(identity) {
            running.task.cancel()
            tasks[identity] = nil
        }
    }

    private func identity(_ record: WebsiteIconRecord?) -> WebsiteIconIdentity? {
        guard let record, !record.deleted, let content = record.content else { return nil }
        return .init(
            library: scope, generation: generation, originID: record.id,
            revision: record.revision, normalizerVersion: content.normalizerVersion,
            digest: content.blob.digest)
    }

    func awaitPendingLoads() async {
        while let running = tasks.values.first { await running.task.value }
    }

    isolated deinit {
        observation?.cancel()
        for running in tasks.values { running.task.cancel() }
    }
}

extension EnvironmentValues {
    @Entry var faviconStore: FaviconStore?
}
