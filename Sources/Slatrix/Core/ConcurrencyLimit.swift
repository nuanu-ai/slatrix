import Foundation

/// Runs at most `slots` operations at once; queued callers that are cancelled leave without running.
actor ConcurrencyLimit {
    private let slots: Int
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(slots: Int) { self.slots = slots }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < slots {
                active += 1
            } else {
                try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }

    // A freed slot passes straight to the next waiter.
    private func release() {
        if !waiting.isEmpty { waiting.removeFirst().1.resume() } else { active -= 1 }
    }
}

/// What `operation` returns, or nil once `limit` passes first. The operation keeps running; a late answer is dropped.
func value<T: Sendable>(within limit: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    let first = FirstAnswer<T>()
    return await withCheckedContinuation { continuation in
        first.wait(continuation)
        Task { first.answer(await operation()) }
        Task {
            try? await Task.sleep(for: limit)
            first.answer(nil)
        }
    }
}

private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    func wait(_ continuation: CheckedContinuation<T?, Never>) { lock.withLock { self.continuation = continuation } }
    func answer(_ value: T?) {
        let waiting = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: value)
    }
}
