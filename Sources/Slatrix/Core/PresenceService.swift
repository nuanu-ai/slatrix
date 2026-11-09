import Foundation

/// Who of the people you message is around. The SDK can't read presence, so this asks the server each minute.
@MainActor @Observable final class PresenceService {
    typealias Fetch = @Sendable (String) async -> String?
    /// Each person's dot, by user ID; empty when the server doesn't share presence.
    private(set) var dots: [String: Presence] = [:]
    /// The server has answered at least once since starting.
    private(set) var checked = false
    private var task: Task<Void, Never>?

    /// `fetch` returns a user's presence state, nil when the server doesn't say; `people` is read every round, so new
    /// conversations join the next one.
    func start(me: String, fetch: @escaping Fetch, people: @escaping @MainActor () -> [String]) {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let own = await fetch(me)
                var next: [String: Presence] = [:]
                if PresencePolicy.shared(own: own) {
                    for person in people() { next[person] = PresencePolicy.dot(own: own, theirs: await fetch(person)) }
                }
                guard let self, !Task.isCancelled else { return }
                if self.dots != next { self.dots = next }
                self.checked = true
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        dots = [:]
        checked = false
    }
}
