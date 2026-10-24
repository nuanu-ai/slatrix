import Foundation
import MatrixRustSDK

private final class RoomObserver: RoomInfoListener, @unchecked Sendable {
    let callback: @Sendable () -> Void
    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
    func call(roomInfo: RoomInfo) { callback() }
}

/// Rebuilds the sidebar's rooms and workspaces from the client's room list.
@MainActor
final class RoomListRefresher {
    private(set) var rooms: [ChatRoom] = []
    private(set) var workspaces: [Workspace] = []
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    private var client: Client?
    private var generation = UUID()
    private var handles: [String: TaskHandle] = [:]
    private var task: Task<Void, Never>?

    func attach(_ client: Client?) {
        generation = UUID()
        task?.cancel()
        task = nil
        pending = false
        for handle in handles.values { handle.cancel() }
        handles.removeAll()
        rooms = []
        workspaces = []
        self.client = client
    }

    private var pending = false

    /// Triggers that arrive during a pass coalesce into one follow-up pass instead of restarting it.
    func request() {
        pending = true
        guard task == nil else { return }
        let generation = generation
        task = Task { [weak self] in
            while let self, self.pending, self.generation == generation, !Task.isCancelled {
                self.pending = false
                await self.refresh()
            }
            if let self, self.generation == generation { self.task = nil }
        }
    }

    private func refresh() async {
        guard let client else { return }
        let generation = generation
        let spaces = await client.spaceService()
        _ = await spaces.topLevelJoinedSpaces()
        var nextRooms: [ChatRoom] = []
        var nextSpaces: [Workspace] = []
        var failure: Error?
        var listed = Set<String>()
        for room in client.rooms() {
            if Task.isCancelled || generation != self.generation { return }
            do {
                switch try await entry(for: room, spaces: spaces, generation: generation) {
                case .room(let value): nextRooms.append(value)
                case .workspace(let value): nextSpaces.append(value)
                case nil: continue
                }
                listed.insert(room.id())
            } catch {
                if Task.isCancelled || generation != self.generation { return }
                listed.insert(room.id())
                // Keep what the sidebar already shows for this room rather than dropping it.
                if let previous = rooms.first(where: { $0.id == room.id() }) {
                    nextRooms.append(previous)
                } else if let previous = workspaces.first(where: { $0.id == room.id() }) {
                    nextSpaces.append(previous)
                } else {
                    failure = failure ?? error
                }
            }
        }
        guard !Task.isCancelled, generation == self.generation else { return }
        for id in handles.keys where !listed.contains(id) { handles.removeValue(forKey: id)?.cancel() }
        let sortedSpaces = nextSpaces.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if nextRooms != rooms || sortedSpaces != workspaces {
            rooms = nextRooms
            workspaces = sortedSpaces
            onChange?()
        }
        if let failure { onError?(failure) }
    }

    private enum Entry {
        case room(ChatRoom)
        case workspace(Workspace)
    }

    private func entry(for room: Room, spaces: SpaceService, generation: UUID) async throws -> Entry? {
        let info = try await room.roomInfo()
        guard generation == self.generation else { throw CancellationError() }
        let placement = InvitationRoomPlacement.classify(isSpace: info.isSpace, membership: info.membership)
        if placement == .ignored { return nil }
        if handles[room.id()] == nil {
            handles[room.id()] = room.subscribeToRoomInfoUpdates(
                listener: RoomObserver { [weak self] in
                    Task { @MainActor [weak self] in self?.request() }
                })
        }
        if placement == .workspace {
            return .workspace(
                Workspace(
                    id: info.id, name: info.displayName ?? info.id, topic: info.topic,
                    canInvite: info.powerLevels?.canOwnUserInvite(),
                    canManageRooms: info.powerLevels?.canOwnUserSendState(stateEvent: .spaceChild),
                    avatarURL: info.avatarUrl,
                    isTopLevel: try await spaces.joinedParentIdsOfChild(childId: info.id).isEmpty))
        }
        var ancestors = Set<String>()
        let directParents = try await spaces.joinedParentIdsOfChild(childId: info.id)
        var pending = directParents
        while let parent = pending.popLast() {
            if ancestors.insert(parent).inserted {
                pending += try await spaces.joinedParentIdsOfChild(childId: parent)
            }
        }
        return .room(
            ChatRoom(
                id: info.id, name: info.displayName ?? info.id, topic: info.topic ?? "",
                isDirect: info.isDirect, isEncrypted: await room.isEncrypted(),
                unread: Int(info.numUnreadNotifications), unreadMessages: Int(info.numUnreadMessages),
                isMarkedUnread: info.isMarkedUnread, mentions: Int(info.numUnreadMentions),
                favorite: info.isFavourite, muted: info.cachedUserDefinedNotificationMode == .mute,
                memberCount: Int(info.activeMembersCount), spaceIDs: ancestors.sorted(),
                membership: info.membership == .invited ? "invite" : "join", avatarURL: info.avatarUrl,
                pinnedEventIDs: info.pinnedEventIds, canPinMessages: info.powerLevels?.canOwnUserPinUnpin(),
                fullyReadEventID: info.fullyReadEventId, isSpace: info.isSpace,
                directParentSpaceIDs: directParents.sorted(), canInvite: info.powerLevels?.canOwnUserInvite()))
    }
}
