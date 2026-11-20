import Observation

/// Waits until `condition` holds or `deadline` passes, checking again whenever an observable value it reads changes.
@MainActor func waitObserving(until condition: @escaping @MainActor () -> Bool, deadline: ContinuousClock.Instant)
    async
{
    let waiter = Waiter()
    let timer = Task { @MainActor in
        try? await Task.sleep(until: deadline)
        waiter.resume()
    }
    defer { timer.cancel() }
    while !condition(), ContinuousClock.now < deadline {
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            withObservationTracking {
                _ = condition()
            } onChange: {
                Task { @MainActor in waiter.resume() }
            }
        }
    }
}

@MainActor private final class Waiter {
    var continuation: CheckedContinuation<Void, Never>?
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
