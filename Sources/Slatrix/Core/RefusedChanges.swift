import Foundation
import MatrixRustSDK

/// A deletion, edit or reaction the server refused stays at the head of its room's send queue, and everything sent
/// there after it waits, even across relaunches. As Slack keeps a message it couldn't delete or edit, each one is
/// cancelled out of the queue, which takes the message back to how the server has it. That happens when the session
/// starts, whenever the server refuses one, and when sending resumes after a reconnect, which also retries a cancel
/// that failed.
@MainActor
final class RefusedChanges {
    private final class Listener: SendQueueRoomUpdateListener, @unchecked Sendable {
        let refused: @Sendable () -> Void
        init(_ refused: @escaping @Sendable () -> Void) { self.refused = refused }
        func onUpdate(roomId: String, update: RoomSendQueueUpdate) {
            // A failure the queue retries by itself is still on its way.
            guard case .sendError(_, _, isRecoverable: false) = update else { return }
            refused()
        }
    }

    private let client: Client
    private let undone: ([RefusedChange]) -> Void
    private var subscription: TaskHandle?
    private var stopped = false

    init(client: Client, undone: @escaping ([RefusedChange]) -> Void) {
        self.client = client
        self.undone = undone
    }

    func start() async throws {
        subscription = try await client.subscribeToSendQueueUpdates(
            listener: Listener { [weak self] in Task { @MainActor in self?.cancel() } })
        cancel()
    }

    func cancel() {
        guard !stopped else { return }
        Task { [client] in
            let changes = (try? await client.abortRefusedChanges()) ?? []
            guard !stopped, !changes.isEmpty else { return }
            undone(changes)
        }
    }

    func stop() {
        stopped = true
        subscription?.cancel()
        subscription = nil
    }
}
