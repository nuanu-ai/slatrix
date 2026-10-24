import Foundation
import MatrixRustSDK

enum RoomReadinessError: LocalizedError {
    case timedOut, noLongerJoined
    var errorDescription: String? {
        switch self {
        case .timedOut: "Channel created, but it isn’t ready yet. Add it to the workspace in a moment."
        case .noLongerJoined: "Channel created, but you’re no longer in it."
        }
    }
}

/// SpaceService reads cached power levels/creators and routes using synced members.
/// A successful createRoom only installs a Joined shell, so membership alone is insufficient.
@MainActor
enum RoomReadiness {
    static func waitUntilReady(
        room: Room, ownUserID: String, timeout: Duration = .seconds(15),
        validate: @escaping @MainActor () throws -> Void
    ) async throws {
        let wait = Wait(room: room, ownUserID: ownUserID, timeout: timeout, validate: validate)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { wait.start($0) }
        } onCancel: {
            Task { @MainActor in wait.finish(.failure(CancellationError())) }
        }
    }

    private struct Snapshot: Sendable {
        let id: String
        let joined: Bool
        let hasCreators: Bool
        let hasPowerLevels: Bool
        init(_ info: RoomInfo) {
            id = info.id
            joined = info.membership == .joined
            hasCreators = info.creators?.isEmpty == false
            hasPowerLevels = info.powerLevels != nil
        }
    }
    private final class Listener: RoomInfoListener, @unchecked Sendable {
        let receive: @Sendable (Snapshot) -> Void
        init(_ receive: @escaping @Sendable (Snapshot) -> Void) { self.receive = receive }
        func call(roomInfo: RoomInfo) { receive(Snapshot(roomInfo)) }
    }
    @MainActor private final class Wait {
        let room: Room
        let ownUserID: String
        let timeout: Duration
        let validate: @MainActor () throws -> Void
        private var continuation: CheckedContinuation<Void, Error>?
        private var completion: Result<Void, Error>?
        private var handle: TaskHandle?
        private var deadline: Task<Void, Never>?
        private var seed: Task<Void, Never>?
        private var members: Task<Void, Never>?
        private var revision: UInt64 = 0

        init(room: Room, ownUserID: String, timeout: Duration, validate: @escaping @MainActor () throws -> Void) {
            self.room = room
            self.ownUserID = ownUserID
            self.timeout = timeout
            self.validate = validate
        }
        func start(_ continuation: CheckedContinuation<Void, Error>) {
            if let completion {
                continuation.resume(with: completion)
                return
            }
            self.continuation = continuation
            do {
                try validate()
                try Task.checkCancellation()
            } catch {
                finish(.failure(error))
                return
            }
            guard room.membership() == .joined else {
                finish(.failure(RoomReadinessError.noLongerJoined))
                return
            }
            handle = room.subscribeToRoomInfoUpdates(
                listener: Listener { [weak self] snapshot in
                    Task { @MainActor [weak self] in self?.receive(snapshot) }
                })
            // Subscribe first, then seed. A late seed must never overwrite a newer callback.
            seed = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let info = try await room.roomInfo()
                    guard !Task.isCancelled, completion == nil, revision == 0 else { return }
                    receive(Snapshot(info))
                } catch {
                    guard !Task.isCancelled, completion == nil, revision == 0 else { return }
                    do { try validate() } catch {
                        finish(.failure(error))
                        return
                    }
                    // Missing initial state is expected; the listener/deadline owns completion.
                }
            }
            let limit = timeout
            deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: limit) } catch { return }
                guard let self, !Task.isCancelled else { return }
                do { try validate() } catch {
                    finish(.failure(error))
                    return
                }
                finish(.failure(RoomReadinessError.timedOut))
            }
        }
        private func receive(_ snapshot: Snapshot) {
            guard completion == nil, snapshot.id == room.id() else { return }
            do { try validate() } catch {
                finish(.failure(error))
                return
            }
            guard snapshot.joined, room.membership() == .joined else {
                finish(.failure(RoomReadinessError.noLongerJoined))
                return
            }
            revision &+= 1
            members?.cancel()
            members = nil
            guard snapshot.hasCreators, snapshot.hasPowerLevels else { return }
            let expected = revision
            members = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let ids = try await room.activeHumanMemberIdsNoSync()
                    guard !Task.isCancelled, completion == nil, revision == expected else { return }
                    try validate()
                    guard room.membership() == .joined else { throw RoomReadinessError.noLongerJoined }
                    guard ids.contains(ownUserID) else { return }
                    finish(.success(()))
                } catch {
                    guard !Task.isCancelled, completion == nil, revision == expected else { return }
                    do { try validate() } catch {
                        finish(.failure(error))
                        return
                    }
                    if room.membership() != .joined { finish(.failure(RoomReadinessError.noLongerJoined)) }
                }
            }
        }
        func finish(_ result: Result<Void, Error>) {
            guard completion == nil else { return }
            completion = result
            handle?.cancel()
            handle = nil
            deadline?.cancel()
            deadline = nil
            seed?.cancel()
            seed = nil
            members?.cancel()
            members = nil
            let pending = continuation
            continuation = nil
            pending?.resume(with: result)
        }
    }
}
