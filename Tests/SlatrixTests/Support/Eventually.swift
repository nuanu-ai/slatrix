import Foundation

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Returns once main-actor work queued before the call has run, such as SDK callbacks that hop to the main actor.
@MainActor
func drainMainActor() async { await Task { @MainActor in }.value }

/// Holds an async operation until the test releases it.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { lock.withLock { !pending.isEmpty } }

    func arm() { lock.withLock { armed = true } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let waits = lock.withLock {
                if armed { pending.append(continuation) }
                return armed
            }
            if !waits { continuation.resume() }
        }
    }
    func release() {
        let waiting = lock.withLock {
            armed = false
            defer { pending = [] }
            return pending
        }
        for item in waiting { item.resume() }
    }
}

/// Holds a synchronous call, like a blocking SDK function, until the test releases it or `limit` passes.
final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var waiting = 0
    var isWaiting: Bool { condition.withLock { waiting > 0 } }

    func arm() { condition.withLock { armed = true } }
    func wait(limit: TimeInterval = 2) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: limit)
        waiting += 1
        while armed, condition.wait(until: deadline) {}
        waiting -= 1
    }
    func release() {
        condition.withLock {
            armed = false
            condition.broadcast()
        }
    }
}

/// A lock-protected log for fakes that SDK callbacks write to from any thread.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    var all: [Value] { lock.withLock { values } }
    func append(_ value: Value) { lock.withLock { values.append(value) } }
}
