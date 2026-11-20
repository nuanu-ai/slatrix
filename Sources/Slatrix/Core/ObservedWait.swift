import Observation

/// The first value `value` has, checked again whenever an observable value it reads changes; nil at `deadline`.
@MainActor func waitObserving<Value>(for value: @escaping @MainActor () -> Value?, deadline: ContinuousClock.Instant)
    async -> Value?
{
    let waiter = Waiter()
    let timer = Task { @MainActor in
        try? await Task.sleep(until: deadline)
        waiter.resume()
    }
    defer { timer.cancel() }
    while ContinuousClock.now < deadline {
        if let found = value() { return found }
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            withObservationTracking {
                _ = value()
            } onChange: {
                Task { @MainActor in waiter.resume() }
            }
        }
    }
    return nil
}

@MainActor private final class Waiter {
    var continuation: CheckedContinuation<Void, Never>?
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
