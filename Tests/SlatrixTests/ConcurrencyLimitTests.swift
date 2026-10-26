import Foundation
import Testing

@testable import Slatrix

private actor Peak {
    private var active = 0
    private(set) var peak = 0
    private(set) var finished = 0
    func begin() {
        active += 1
        peak = max(peak, active)
    }
    func end() {
        active -= 1
        finished += 1
    }
}

struct ConcurrencyLimitTests {
    @Test("Never runs more operations at once than its slots, and runs them all", arguments: [1, 2, 3])
    func capsConcurrency(slots: Int) async {
        let limit = ConcurrencyLimit(slots: slots)
        let peak = Peak()
        let gate = Gate()
        gate.arm()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await limit.run {
                        await peak.begin()
                        await gate.wait()
                        await peak.end()
                    }
                }
            }
            while await peak.peak < slots { await Task.yield() }
            gate.release()
        }
        #expect(await peak.peak == slots)
        #expect(await peak.finished == 8)
    }

    @Test("A queued caller that is cancelled never runs and frees its place")
    func cancelledWaiterSkips() async throws {
        let limit = ConcurrencyLimit(slots: 1)
        let gate = Gate()
        gate.arm()
        let holder = Task { try await limit.run { await gate.wait() } }
        while !gate.isWaiting { await Task.yield() }
        let ran = Peak()
        let queued = Task { try await limit.run { await ran.begin() } }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        gate.release()
        try await holder.value
        try await limit.run {}
        #expect(await ran.peak == 0)
    }
}

struct DeadlineTests {
    @Test("Work that never finishes is given up once the limit passes")
    func givesUp() async {
        let gate = Gate()
        gate.arm()
        defer { gate.release() }
        let value = await value(within: .milliseconds(50)) { () -> Int? in
            await gate.wait()
            return 1
        }
        #expect(value == nil)
    }

    @Test("Work that finishes in time keeps its answer")
    func keepsAnswer() async {
        #expect(await value(within: .seconds(5)) { 7 } == 7)
    }
}
