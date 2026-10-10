import Foundation
import Testing

@testable import CapdWebsiteIcons

struct LegacyWebsiteIconReaderTests {
    @Test func initialReadsShareBoundedAdmissionAndTwoWorkers() async throws {
        let gate = LegacyReadGate()
        let reader = LegacyWebsiteIconReader(load: { _ in await gate.read() })
        let tasks = (0..<100).map { index in
            Task {
                let bytes = try await reader.read(
                    at: URL(fileURLWithPath: "/synthetic/\(index).png"))
                if bytes == nil { await gate.refuse() }
                return bytes
            }
        }
        while await reader.admitted < 16 { await Task.yield() }
        while await gate.count < 2 { await Task.yield() }
        while await gate.refused < 84 { await Task.yield() }
        #expect(await reader.active == 2)
        #expect(await gate.count == 2)
        await gate.release()
        var loaded = 0
        for task in tasks { if try await task.value != nil { loaded += 1 } }
        #expect(loaded == 16)
        #expect(await reader.admitted == 0)
        #expect(await reader.active == 0)
        #expect(await gate.maximum == 2)
    }
}

private actor LegacyReadGate {
    var count = 0
    var refused = 0
    var maximum = 0
    private var active = 0
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func refuse() { refused += 1 }

    func read() async -> Data {
        active += 1
        count += 1
        maximum = max(maximum, active)
        if !open { await withCheckedContinuation { waiting.append($0) } }
        active -= 1
        return Data([1])
    }

    func release() {
        open = true
        for waiter in waiting { waiter.resume() }
        waiting = []
    }
}
