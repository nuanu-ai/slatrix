import Foundation
import MatrixRustSDK

struct InvitationDestination: Equatable {
    enum Kind: Equatable { case room, workspace }
    let id: String
    let kind: Kind
}

enum InvitationAction: Equatable { case accept, decline }

enum InvitationRoomPlacement: Equatable {
    case conversation, workspace, ignored
    static func classify(isSpace: Bool, membership: Membership) -> Self {
        switch membership {
        case .invited: return .conversation
        case .joined: return isSpace ? .workspace : .conversation
        default: return .ignored
        }
    }
}

@MainActor
final class InvitationActions {
    private struct Pending {
        let id: UUID
        let action: InvitationAction
        let task: Task<InvitationDestination, Error>
    }
    private var generation = UUID()
    private var pending: [String: Pending] = [:]
    private let onPendingChanged: (Set<String>) -> Void
    init(onPendingChanged: @escaping (Set<String>) -> Void = { _ in }) { self.onPendingChanged = onPendingChanged }

    func perform(room: Room, action: InvitationAction, isCurrent: @escaping @MainActor () -> Bool) async throws
        -> InvitationDestination
    {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let roomID = room.id()
        let account = generation
        if let existing = pending[roomID] {
            guard existing.action == action else {
                throw MatrixServiceError.request("An invitation action is already in progress for this conversation.")
            }
            let result = try await existing.task.value
            try Task.checkCancellation()
            guard generation == account, isCurrent() else { throw CancellationError() }
            return result
        }
        guard room.membership() == .invited else {
            throw MatrixServiceError.request("This invitation is no longer pending. Refresh your conversations.")
        }
        let destination = InvitationDestination(id: roomID, kind: room.isSpace() ? .workspace : .room)
        let request = UUID()
        // UniFFI membership requests aren't cancelled by Swift Task cancellation.
        // Retain the real request until completion so a second click cannot duplicate it.
        let task = Task { @MainActor [weak self] in
            guard let self, self.generation == account, isCurrent() else { throw CancellationError() }
            guard room.membership() == .invited else {
                throw MatrixServiceError.request("This invitation is no longer pending. Refresh your conversations.")
            }
            switch action {
            case .accept: try await room.join()
            case .decline: try await room.leave()
            }
            guard self.generation == account, isCurrent() else { throw CancellationError() }
            // Sync can still report Invited briefly after the successful SDK call.
            let membership = room.membership()
            guard membership == .invited || (action == .accept ? membership == .joined : membership == .left) else {
                throw CancellationError()
            }
            return destination
        }
        pending[roomID] = Pending(id: request, action: action, task: task)
        onPendingChanged(Set(pending.keys))
        let result = await task.result
        if generation == account, pending[roomID]?.id == request {
            pending.removeValue(forKey: roomID)
            onPendingChanged(Set(pending.keys))
        }
        try Task.checkCancellation()
        guard generation == account, isCurrent() else { throw CancellationError() }
        return try result.get()
    }

    func reset() {
        generation = UUID()
        pending.removeAll()
        onPendingChanged([])
    }
}

@MainActor
enum InvitationPermissions {
    static func invite(room: Room, userID: String, validate: () throws -> Void) async throws {
        try validate()
        guard room.membership() == .joined else {
            throw MatrixServiceError.request("Join this conversation before inviting people.")
        }
        let info = try await room.roomInfo()
        try validate()
        let powers: RoomPowerLevels
        if let cached = info.powerLevels {
            powers = cached
        } else {
            powers = try await room.getPowerLevels()
            try validate()
        }
        guard room.membership() == .joined, powers.canOwnUserInvite() else {
            throw MatrixServiceError.request("You do not have permission to invite people to this conversation.")
        }
        try await room.inviteUserById(userId: userID)
        try validate()
    }

    static func updateSpaceLink(
        space: Room, child: Room, spaces: SpaceService, adding: Bool, validate: () throws -> Void
    ) async throws {
        try validate()
        guard space.isSpace(), !child.isSpace(), space.id() != child.id(),
            space.membership() == .joined, child.membership() == .joined
        else {
            throw MatrixServiceError.request("Join the workspace and channel before changing their connection.")
        }
        let info = try await space.roomInfo()
        try validate()
        let powers: RoomPowerLevels
        if let cached = info.powerLevels {
            powers = cached
        } else {
            powers = try await space.getPowerLevels()
            try validate()
        }
        guard space.membership() == .joined, child.membership() == .joined,
            powers.canOwnUserSendState(stateEvent: .spaceChild)
        else {
            throw MatrixServiceError.request("You do not have permission to manage channels in this workspace.")
        }
        _ = await spaces.topLevelJoinedSpaces()
        try validate()
        let parents = try await spaces.joinedParentIdsOfChild(childId: child.id())
        try validate()
        let direct = parents.contains(space.id())
        if adding && direct { return }
        guard adding || direct else {
            throw MatrixServiceError.request(
                "This channel isn’t in that workspace.")
        }
        guard space.membership() == .joined, child.membership() == .joined else { throw CancellationError() }
        if adding {
            try await spaces.addChildToSpace(childId: child.id(), spaceId: space.id())
        } else {
            try await spaces.removeChildFromSpace(childId: child.id(), spaceId: space.id())
        }
        try validate()
    }
}
