import Foundation
import MatrixRustSDK

private final class RoomObserver: RoomInfoListener, @unchecked Sendable {
    let callback: @Sendable () -> Void
    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
    func call(roomInfo: RoomInfo) { callback() }
}

/// Rebuilds the sidebar's rooms and workspaces from the client's room list. SDK calls and building the values run
/// off the main actor, which only swaps in the finished arrays.
@MainActor
final class RoomListRefresher {
    private(set) var rooms: [ChatRoom] = []
    private(set) var workspaces: [Workspace] = []
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    private var client: Client?
    private var generation = UUID()
    private var state = State()
    private var task: Task<Void, Never>?
    private var full = false
    private var changed: [String: Room] = [:]

    func attach(_ client: Client?) {
        generation = UUID()
        task?.cancel()
        task = nil
        full = false
        changed = [:]
        for handle in state.handles.values { handle.cancel() }
        state = State()
        rooms = []
        workspaces = []
        self.client = client
    }

    /// Rereads every room. Triggers that arrive during a pass coalesce into one follow-up pass instead of restarting it.
    func request() {
        full = true
        run()
    }

    private func roomChanged(_ room: Room, id: String, generation: UUID) {
        guard generation == self.generation else { return }
        changed[id] = room
        run()
    }

    private func run() {
        guard task == nil, let client else { return }
        let generation = generation
        let listen: @Sendable (Room, String) -> RoomInfoListener = { [weak self] room, id in
            RoomObserver { [weak self] in
                Task { @MainActor [weak self] in self?.roomChanged(room, id: id, generation: generation) }
            }
        }
        task = Task { [weak self] in
            while let self, self.generation == generation, !Task.isCancelled, self.full || !self.changed.isEmpty {
                let only = self.full ? nil : self.changed
                self.full = false
                self.changed = [:]
                let interval = Performance.begin(.roomlistRefresh)
                let outcome = await Self.pass(
                    client, self.state, only: only, published: (self.rooms, self.workspaces), listen: listen)
                Performance.end(interval, ["rooms": outcome.read])
                guard self.generation == generation, !Task.isCancelled else {
                    for handle in outcome.state.handles.values { handle.cancel() }
                    return
                }
                self.state = outcome.state
                if let (rooms, workspaces) = outcome.sidebar {
                    self.rooms = rooms
                    self.workspaces = workspaces
                    self.onChange?()
                }
                if let failure = outcome.failure { self.onError?(failure) }
            }
            if let self, self.generation == generation { self.task = nil }
        }
    }

    private enum Entry {
        case room(ChatRoom)
        case workspace(Workspace)
    }

    /// What one pass leaves for the next.
    private struct State {
        /// Listed rooms in the client's order.
        var order: [String] = []
        var entries: [String: Entry] = [:]
        /// The joined spaces each listed room sits directly in.
        var parents: [String: [String]] = [:]
        var handles: [String: TaskHandle] = [:]
        var spaces: SpaceService?
    }

    private struct Outcome {
        var state: State
        /// Set only when the sidebar changed.
        var sidebar: ([ChatRoom], [Workspace])?
        var failure: Error?
        var read: Int
    }

    private enum Fetched {
        case listed(RoomInfo, isEncrypted: Bool, parents: [String])
        case ignored
        case failed(Error)
    }

    /// Rereads `only` those rooms, or every room when nil, and rebuilds the sidebar from what changed.
    nonisolated private static func pass(
        _ client: Client, _ previous: State, only: [String: Room]?, published: ([ChatRoom], [Workspace]),
        listen: @escaping @Sendable (Room, String) -> RoomInfoListener
    ) async -> Outcome {
        var state = previous
        let spaces: SpaceService
        if let existing = state.spaces {
            spaces = existing
        } else {
            spaces = await client.spaceService()
            state.spaces = spaces
        }
        let targets: [(id: String, room: Room)]
        if let only {
            targets = only.map { ($0.key, $0.value) }
        } else {
            // Rebuilds the space graph, which joinedParentIdsOfChild doesn't.
            _ = await spaces.topLevelJoinedSpaces()
            targets = client.rooms().map { ($0.id(), $0) }
        }
        // Space ancestry changes only with a space, so a partial pass reuses the parents it already knows.
        let fetched = await fetch(targets, spaces: spaces, knownParents: only == nil ? [:] : state.parents)
        if Task.isCancelled { return Outcome(state: state, read: targets.count) }
        if only != nil,
            fetched.values.contains(where: { if case .listed(let info, _, _) = $0 { info.isSpace } else { false } })
                || targets.contains(where: { if case .workspace = state.entries[$0.id] { true } else { false } })
        {
            return await pass(client, state, only: nil, published: published, listen: listen)
        }

        var failure: Error?
        var infos: [String: (RoomInfo, Bool)] = [:]
        if only == nil {
            state.order = []
            state.entries = [:]
            state.parents = [:]
        }
        for (id, room) in targets {
            switch fetched[id] {
            case .listed(let info, let isEncrypted, let parents):
                infos[id] = (info, isEncrypted)
                state.parents[id] = parents
                if only == nil || previous.entries[id] == nil { state.order.append(id) }
                if state.handles[id] == nil {
                    state.handles[id] = room.subscribeToRoomInfoUpdates(listener: listen(room, id))
                }
            case .failed(let error):
                // Keep what the sidebar already shows for this room rather than dropping it.
                if let entry = previous.entries[id] {
                    state.entries[id] = entry
                    state.parents[id] = previous.parents[id]
                    if only == nil { state.order.append(id) }
                } else {
                    failure = failure ?? error
                }
            case .ignored, nil:
                state.order.removeAll { $0 == id }
                state.entries[id] = nil
                state.parents[id] = nil
                state.handles.removeValue(forKey: id)?.cancel()
            }
        }
        if only == nil {
            let listed = Set(state.order)
            for id in state.handles.keys where !listed.contains(id) { state.handles.removeValue(forKey: id)?.cancel() }
        }
        for (id, (info, isEncrypted)) in infos {
            state.entries[id] = entry(info, isEncrypted: isEncrypted, parents: state.parents)
        }

        var rooms: [ChatRoom] = []
        var workspaces: [Workspace] = []
        for id in state.order {
            switch state.entries[id] {
            case .room(let value): rooms.append(value)
            case .workspace(let value): workspaces.append(value)
            case nil: continue
            }
        }
        workspaces.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let sidebar = rooms != published.0 || workspaces != published.1 ? (rooms, workspaces) : nil
        return Outcome(state: state, sidebar: sidebar, failure: failure, read: targets.count)
    }

    /// Reads the rooms a few at a time, so one slow room doesn't hold up the rest.
    nonisolated private static func fetch(
        _ targets: [(id: String, room: Room)], spaces: SpaceService, knownParents: [String: [String]]
    ) async -> [String: Fetched] {
        await withTaskGroup(of: (String, Fetched).self) { group in
            var results: [String: Fetched] = [:]
            var next = targets.makeIterator()
            var running = 0
            while true {
                while running < 8, let (id, room) = next.next() {
                    running += 1
                    group.addTask { (id, await fetch(room, id: id, spaces: spaces, knownParents: knownParents[id])) }
                }
                guard let (id, result) = await group.next() else { return results }
                running -= 1
                results[id] = result
            }
        }
    }

    nonisolated private static func fetch(
        _ room: Room, id: String, spaces: SpaceService, knownParents: [String]?
    ) async -> Fetched {
        do {
            let info = try await room.roomInfo()
            if InvitationRoomPlacement.classify(isSpace: info.isSpace, membership: info.membership) == .ignored {
                return .ignored
            }
            let isEncrypted = await room.isEncrypted()
            if let knownParents { return .listed(info, isEncrypted: isEncrypted, parents: knownParents) }
            let parents = try await spaces.joinedParentIdsOfChild(childId: id)
            return .listed(info, isEncrypted: isEncrypted, parents: parents)
        } catch {
            return .failed(error)
        }
    }

    nonisolated private static func entry(_ info: RoomInfo, isEncrypted: Bool, parents: [String: [String]]) -> Entry {
        let directParents = parents[info.id] ?? []
        if InvitationRoomPlacement.classify(isSpace: info.isSpace, membership: info.membership) == .workspace {
            return .workspace(
                Workspace(
                    id: info.id, name: info.displayName ?? info.id, topic: info.topic,
                    canInvite: info.powerLevels?.canOwnUserInvite(),
                    canManageRooms: info.powerLevels?.canOwnUserSendState(stateEvent: .spaceChild),
                    avatarURL: info.avatarUrl, isTopLevel: directParents.isEmpty))
        }
        var ancestors = Set<String>()
        var pending = directParents
        while let parent = pending.popLast() {
            if ancestors.insert(parent).inserted { pending += parents[parent] ?? [] }
        }
        return .room(
            ChatRoom(
                id: info.id, name: info.displayName ?? info.id, topic: info.topic ?? "",
                isDirect: info.isDirect, isEncrypted: isEncrypted,
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
