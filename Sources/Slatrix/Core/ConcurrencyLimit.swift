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
