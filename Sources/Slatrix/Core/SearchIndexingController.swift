import Foundation

enum SearchIndexingState: Equatable {
    case idle, running, stopping, stopped, completed
    var isBusy: Bool { self == .running || self == .stopping }
}

/// Owns the official SDK task through its actual completion. Cancelling the
/// sweep does not undo indexed messages or prevent a shared request finishing.
@MainActor
final class SearchIndexingController {
    struct Handle {
        let cancel: () -> Void
        let isFinished: () -> Bool
    }
    private(set) var state: SearchIndexingState = .idle
    private var generation = UUID()
    private var handle: Handle?
    private var watch: Task<Void, Never>?
    private var onUpdate: ((SearchIndexingState) -> Void)?
    private let wait: @MainActor () async throws -> Void

    init(wait: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(750)) }) {
        self.wait = wait
    }

    func start(makeHandle: () -> Handle, onUpdate: @escaping (SearchIndexingState) -> Void) {
        guard !state.isBusy else { return }
        let token = UUID()
        generation = token
        self.onUpdate = onUpdate
        let handle = makeHandle()
        self.handle = handle
        publish(.running)
        let wait = self.wait
        watch = Task { @MainActor [weak self] in
            while !handle.isFinished() {
                do { try await wait() } catch { return }
                guard let self, self.generation == token else { return }
            }
            guard let self, self.generation == token else { return }
            let result: SearchIndexingState = self.state == .stopping ? .stopped : .completed
            self.handle = nil
            self.watch = nil
            self.publish(result)
        }
    }

    func cancel() {
        guard state == .running, let handle else { return }
        publish(.stopping)
        handle.cancel()
        // Keep the watcher and busy state until isFinished acknowledges abort.
    }

    func reset() {
        generation = UUID()
        watch?.cancel()
        watch = nil
        handle?.cancel()
        handle = nil
        onUpdate = nil
        state = .idle
    }

    private func publish(_ value: SearchIndexingState) {
        state = value
        onUpdate?(value)
    }
}
