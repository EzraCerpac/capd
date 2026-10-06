import CapdKit
import Foundation

actor WebsiteIconQueue {
    private let service: WebsiteIconService
    private var draining = false

    init(service: WebsiteIconService) { self.service = service }

    func drain(limit: Int = 3) async {
        guard !draining, limit > 0 else { return }
        draining = true
        defer { draining = false }
        do {
            _ = try service.reclaimStale()
            for _ in 0..<min(limit, 3) {
                try Task.checkCancellation()
                if try await !service.processNext() { return }
            }
        } catch {}
    }
}
