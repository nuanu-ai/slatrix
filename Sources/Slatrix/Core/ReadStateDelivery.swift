import Foundation

// Cancellation is recorded independently of the operation task. Cancelling a
// task already awaiting UniFFI could release its successor before the write has
// actually finished, reversing a later explicit Mark unread operation.
private final class ReadStateRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false

    func cancelIfQueued() {
        lock.withLock { if !started { cancelled = true } }
    }

    func begin() -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            started = true
            return true
        }
    }
}

@MainActor
final class ReadStateDelivery {
    private struct Tail {
        let id: UUID
        let cancellation: ReadStateRequestCancellation
        let task: Task<Void, Error>
    }
    private var generation = UUID()
    private var tails: [String: Tail] = [:]

    func perform(roomID: String, operation: @escaping @MainActor () async throws -> Void) async throws {
        try Task.checkCancellation()
        let account = generation
        let request = UUID()
        let predecessor = tails[roomID]?.task
        let cancellation = ReadStateRequestCancellation()
        let task = Task { @MainActor [weak self] in
            // A failed/cancelled predecessor still establishes ordering, but
            // must not poison subsequent explicit writes for this room.
            if let predecessor { _ = await predecessor.result }
            guard let self, self.generation == account, cancellation.begin() else { throw CancellationError() }
            try await operation()
            guard self.generation == account else { throw CancellationError() }
        }
        tails[roomID] = Tail(id: request, cancellation: cancellation, task: task)
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            cancellation.cancelIfQueued()
        }
        // A reset or a newer request may already own this room's tail.
        if tails[roomID]?.id == request { tails.removeValue(forKey: roomID) }
        try Task.checkCancellation()
        try result.get()
    }

    // Account/session boundary: queued closures from the previous generation
    // never start. Already-started operations finish their await without task
    // cancellation, then return CancellationError to their original caller.
    func reset() {
        generation = UUID()
        for tail in tails.values { tail.cancellation.cancelIfQueued() }
        tails.removeAll()
    }
}
