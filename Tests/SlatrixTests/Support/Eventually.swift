import Foundation

/// Polls `condition` on the main actor every 5 ms until it holds, giving up after `timeout` worth of polls. It counts
/// polls, not clock time: at the start of a parallel run on CI's cold runners, other tests' main-actor work (AppKit's
/// first text views above all) holds the main actor for seconds, and the clock would run out while the work being
/// waited for is still queued behind it. A poll held back like that counts once.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let interval = Duration.milliseconds(5)
    for _ in 0..<Int(timeout / interval) {
        if condition() { return true }
        try? await Task.sleep(for: interval)
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

/// A lock-protected log for fakes that SDK callbacks write to from any thread.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    var all: [Value] { lock.withLock { values } }
    func append(_ value: Value) { lock.withLock { values.append(value) } }
}
