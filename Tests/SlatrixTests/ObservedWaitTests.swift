import Testing

@testable import Slatrix

/// A value nothing observes: only a fresh look sees it change.
@MainActor private final class Plain {
    var value: Bool?
}

@MainActor
struct ObservedWaitTests {
    @Test("An answer that comes without an observable change is still taken at the deadline")
    func lastLookAtDeadline() async {
        let plain = Plain()
        let wait = Task { await waitObserving(for: { plain.value }, deadline: .now + .milliseconds(50)) }
        await drainMainActor()
        plain.value = true
        #expect(await wait.value == true)
    }
}
