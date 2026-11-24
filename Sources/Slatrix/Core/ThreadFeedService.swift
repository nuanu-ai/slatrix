import Foundation
import MatrixRustSDK
import Observation

/// A thread as the thread list last reported it; `root` and `latest` are placeholders until their previews hydrate.
struct ThreadFeedItem: Identifiable, Hashable {
    var id: String
    var roomID: String
    var roomName: String
    var isDirect = false
    var isPrivate = false
    var root: ChatMessage
    var latest: ChatMessage?
    var replyCount: Int
    var isUnread = false
    var lastActivityAt: Date { latest?.timestamp ?? root.timestamp }
}

/// One thread message's current content. Hydration changes only this, so only the row showing it redraws.
@MainActor
@Observable final class ThreadPreview {
    enum State: String, Hashable { case snapshot, loading, ready, failed }
    fileprivate(set) var state = State.snapshot
    fileprivate(set) var message: ChatMessage?
    fileprivate(set) var error: String?

    fileprivate init(state: State, message: ChatMessage?, error: String?) {
        self.state = state
        self.message = message
        self.error = error
    }

    /// What a row shows for `snapshot`, the thread list's placeholder for this message.
    func shown(_ snapshot: ChatMessage) -> ChatMessage {
        guard var message else { return ThreadFeedService.placeholder(snapshot, failed: state == .failed) }
        message.replyCount = snapshot.replyCount
        return message
    }
}

struct ThreadFeedRoomState: Identifiable, Hashable {
    enum State: String, Hashable { case unloaded, loading, ready, error }
    var id: String
    var name: String
    var state: State = .unloaded
    var hasMore = true
    var errorMessage: String? = nil
}

enum ThreadFeedMapping {
    static func isInScope(_ room: ChatRoom, workspaceID: String?) -> Bool {
        room.membership == "join" && (room.isDirect || (workspaceID.map { room.spaceIDs.contains($0) } ?? true))
    }

    static func message(_ event: ThreadListItemEvent, roomID: String) -> ChatMessage {
        let name = MatrixMapping.profileName(event.senderProfile, userID: event.sender)
        var message: ChatMessage
        if case .msgLike(let content) = event.content {
            message = MatrixMapping.project(
                content, id: event.eventId, roomID: roomID, senderID: event.sender, senderName: name,
                timestamp: event.timestamp)
        } else {
            message = ChatMessage(
                id: event.eventId, roomID: roomID, senderID: event.sender, senderName: name,
                body: "Thread message is not available yet",
                timestamp: Date(timeIntervalSince1970: Double(event.timestamp) / 1000), kind: "unavailable")
        }
        if message.formattedBody?.localizedCaseInsensitiveContains("data-mx-spoiler") == true {
            message.body = "[Spoiler hidden]"
        }
        if case .ready(_, _, let avatar, _, _) = event.senderProfile { message.avatarURL = avatar }
        return message
    }

    static func isRead(_ latest: ThreadListItemEvent, by receipt: UserReceipt?) -> Bool {
        guard let receipt else { return false }
        if receipt.eventId == latest.eventId { return true }
        if let timestamp = receipt.receipt.timestamp, timestamp >= latest.timestamp { return true }
        return false
    }

    static func isUnread(
        latest: ThreadListItemEvent?, ownUserID: String?, threadReceipt: UserReceipt?, unthreadedReceipt: UserReceipt?
    ) -> Bool {
        guard let latest, let ownUserID, !latest.isOwn, latest.sender != ownUserID else { return false }
        return !isRead(latest, by: threadReceipt) && !isRead(latest, by: unthreadedReceipt)
    }

    static func project(
        _ values: [ThreadListItem], room: ChatRoom, ownUserID: String? = nil,
        threadReceipts: [String: UserReceipt] = [:], unthreadedReceipt: UserReceipt? = nil,
        locallyRead: [String: String] = [:]
    ) -> [ThreadFeedItem] {
        var unique: [String: ThreadFeedItem] = [:]
        for value in values {
            var root = message(value.rootEvent, roomID: room.id)
            root.replyCount = Int(value.numReplies)
            let id = ActivityService.key(roomID: room.id, eventID: root.eventID)
            let latestEvent = value.latestEvent
            let readLocally = latestEvent.map { locallyRead[id] == $0.eventId } ?? false
            let unread =
                !readLocally
                && isUnread(
                    latest: latestEvent, ownUserID: ownUserID, threadReceipt: threadReceipts[root.eventID],
                    unthreadedReceipt: unthreadedReceipt)
            let item = ThreadFeedItem(
                id: id, roomID: room.id, roomName: room.name, isDirect: room.isDirect, isPrivate: room.isPrivate,
                root: root,
                latest: latestEvent.map { message($0, roomID: room.id) }, replyCount: Int(value.numReplies),
                isUnread: unread)
            if unique[id].map({ $0.lastActivityAt > item.lastActivityAt }) != true { unique[id] = item }
        }
        return Array(unique.values)
    }
}

private final class ThreadFeedItemsObserver: ThreadListEntriesListener, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ThreadListItem] = []
    private var revision = 0
    let callback: @Sendable ([ThreadListItem], Int) -> Void
    init(_ callback: @escaping @Sendable ([ThreadListItem], Int) -> Void) { self.callback = callback }
    func onUpdate(diff: [ThreadListUpdate]) {
        lock.lock()
        items.apply(diff.map(\.change))
        revision += 1
        let snapshot = items
        let next = revision
        lock.unlock()
        callback(snapshot, next)
    }
}

private final class ThreadFeedPaginationObserver: ThreadListPaginationStateListener, @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    let callback: @Sendable (ThreadListPaginationState, Int) -> Void
    init(_ callback: @escaping @Sendable (ThreadListPaginationState, Int) -> Void) { self.callback = callback }
    func onUpdate(state: ThreadListPaginationState) {
        lock.lock()
        revision += 1
        let next = revision
        lock.unlock()
        callback(state, next)
    }
}

private final class ThreadPreviewObserver: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    let callback: @Sendable (Int) -> Void
    init(_ callback: @escaping @Sendable (Int) -> Void) { self.callback = callback }
    func onUpdate(diff: [TimelineDiff]) {
        lock.lock()
        revision += 1
        let next = revision
        lock.unlock()
        callback(next)
    }
}

/// Serializes complete subscription snapshots; selection, feed and mutations share one union.
@MainActor
final class RoomSubscriptionCoordinator {
    private var service: RoomListService?
    private var activeRoomID: String?
    private var feedRoomIDs = Set<String>()
    private var recentRoomIDs = Set<String>()
    private var mutationRooms: [UUID: String] = [:]
    private var generation = UUID()
    private var pending: Task<Void, Error>?

    func attach(_ service: RoomListService?) {
        generation = UUID()
        pending?.cancel()
        pending = nil
        self.service = service
        activeRoomID = nil
        feedRoomIDs = []
        recentRoomIDs = []
        mutationRooms = [:]
    }

    /// `recent` are the conversations kept open for coming back to.
    func setActiveRoom(_ roomID: String?, recent: [String] = []) async throws {
        activeRoomID = roomID
        recentRoomIDs = Set(recent)
        try await enqueue()
    }
    func setFeedRooms(_ roomIDs: Set<String>) async throws {
        feedRoomIDs = roomIDs
        try await enqueue()
    }

    /// Keeps a newly created room syncing without changing selection or replacing feed rooms.
    func withMutationRoom<T>(roomID: String, operation: @MainActor () async throws -> T) async throws -> T {
        let lease = UUID()
        let account = generation
        mutationRooms[lease] = roomID
        do {
            try await enqueue()
            try Task.checkCancellation()
            guard generation == account else { throw CancellationError() }
            let result = try await operation()
            try Task.checkCancellation()
            guard generation == account else { throw CancellationError() }
            await releaseMutation(lease, account: account)
            guard generation == account else { throw CancellationError() }
            return result
        } catch {
            await releaseMutation(lease, account: account)
            guard generation == account else { throw CancellationError() }
            throw error
        }
    }

    private func releaseMutation(_ lease: UUID, account: UUID) async {
        guard generation == account, mutationRooms.removeValue(forKey: lease) != nil else { return }
        // Linking success must not become a false write failure if subscription cleanup fails.
        // The next active/feed/mutation snapshot retries the desired union without this lease.
        try? await enqueue()
    }

    static func combined(
        activeRoomID: String?, feedRoomIDs: Set<String>, mutationRoomIDs: Set<String> = []
    ) -> [String] {
        var rooms = feedRoomIDs.union(mutationRoomIDs)
        if let activeRoomID { rooms.insert(activeRoomID) }
        return rooms.sorted()
    }

    private func enqueue() async throws {
        guard let service else { throw MatrixServiceError.signedOut }
        let target = Self.combined(
            activeRoomID: activeRoomID, feedRoomIDs: feedRoomIDs.union(recentRoomIDs),
            mutationRoomIDs: Set(mutationRooms.values))
        let previous = pending
        let token = generation
        let next = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            guard let self, self.generation == token, !Task.isCancelled else { throw CancellationError() }
            try await service.setRoomSubscriptions(roomIds: target)
            guard self.generation == token, !Task.isCancelled else { throw CancellationError() }
        }
        pending = next
        try await next.value
    }
}

@MainActor
@Observable final class ThreadFeedService {
    private(set) var items: [ThreadFeedItem] = []
    private(set) var roomStates: [ThreadFeedRoomState] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var liveRoomCount = 0
    var checkedRoomCount: Int { roomStates.filter { $0.state == .ready || $0.state == .error }.count }
    var totalRoomCount: Int { roomStates.count }
    var canCheckMore: Bool { roomStates.contains { $0.state == .unloaded } }
    private(set) var isActive = false
    /// True while opening checks every room's first page and the first screen's current text, so the list shows once,
    /// in its final order, instead of rows arriving and moving under the reader.
    private(set) var isDiscovering = false
    // Thread-list pages and the preview timelines in the feed share two requests at a time.
    private let limit = ConcurrencyLimit(slots: 2)
    private var client: Client?
    private var workspaceID: String?
    private var ownUserID: String?
    private var rooms: [ChatRoom] = []
    private var generation = UUID()
    private var subscriptionOrder: [String] = []
    private var subscriptions: ((Set<String>) async throws -> Void)?
    private final class Record {
        let room: Room
        let service: ThreadListService
        let token = UUID()
        var handles: [TaskHandle] = []
        var values: [ThreadListItem] = [] { didSet { projected = nil } }
        var unthreadedReceipt: UserReceipt?
        var threadReceipts: [String: UserReceipt] = [:]
        var receiptRevision = 0
        var receiptTask: Task<Void, Never>?
        /// `values` as rows, kept until they or the room change; projecting every room on each page is the cost.
        var projected: [ThreadFeedItem]?
        var revision = 0
        var paginationRevision = 0
        init(room: Room, service: ThreadListService) {
            self.room = room
            self.service = service
        }
        func cancel() {
            receiptTask?.cancel()
            receiptTask = nil
            for item in handles { item.cancel() }
            handles = []
        }
    }
    private var records: [String: Record] = [:]
    private final class Preview {
        let token = UUID()
        var state = ThreadPreview.State.loading
        var message: ChatMessage?
        var error: String?
        var revision = 0
        var timeline: Timeline?
        var handle: TaskHandle?
        var task: Task<Void, Never>?
        func cancel() {
            task?.cancel()
            handle?.cancel()
            task = nil
            handle = nil
            timeline = nil
        }
    }
    // Rows build their previews in the feed's body; observing these would tie every row to every hydration.
    @ObservationIgnored private var previews: [String: Preview] = [:]
    @ObservationIgnored private var previewOrder: [String] = []
    @ObservationIgnored private var shownPreviews: [String: ThreadPreview] = [:]
    /// What the feed last showed and each message's current content, kept across closing so a reopened feed shows
    /// them at once while it checks again; signing out forgets them.
    @ObservationIgnored private var lastShown: (workspaceID: String?, items: [ThreadFeedItem])?
    @ObservationIgnored private var current: [String: ChatMessage] = [:]
    private struct UnreadSnapshot: Equatable {
        var unread: Int
        var unreadMessages: Int
        var mentions: Int
        var isMarkedUnread: Bool
        func decreased(from previous: Self) -> Bool {
            unread < previous.unread || unreadMessages < previous.unreadMessages || mentions < previous.mentions
                || (previous.isMarkedUnread && !isMarkedUnread)
        }
    }
    /// Latest reply event ID already confirmed read locally, by thread key, so read state clears before sync echoes.
    @ObservationIgnored private var locallyReadThreads: [String: String] = [:]
    @ObservationIgnored private var unreadByRoom: [String: UnreadSnapshot] = [:]
    private static let firstScreen = 8
    @ObservationIgnored private var publishPending = false

    func open(
        client: Client, rooms: [ChatRoom], workspaceID: String?, ownUserID: String? = nil,
        subscriptions: @escaping (Set<String>) async throws -> Void
    ) async {
        close()
        isActive = true
        self.client = client
        self.workspaceID = workspaceID
        self.ownUserID = ownUserID
        self.subscriptions = subscriptions
        let token = generation
        if let lastShown, lastShown.workspaceID == workspaceID { items = lastShown.items }
        isDiscovering = true
        defer { if generation == token { isDiscovering = false } }
        updateRooms(rooms)
        if self.rooms.isEmpty {
            do { try await subscriptions([]) } catch {
                if generation == token { errorMessage = MatrixService.safeError(error) }
            }
        }
        while generation == token, isActive, !Task.isCancelled, canCheckMore {
            let pending = Set(roomStates.filter { $0.state == .unloaded }.map(\.id))
            await checkMore()
            guard generation == token else { return }
            // A cancelled or competing operation must not turn automatic discovery into a busy loop.
            if Set(roomStates.filter { $0.state == .unloaded }.map(\.id)) == pending { break }
        }
        guard generation == token else { return }
        // The thread list carries messages as first sent, so the first screen waits for its current text, briefly.
        let first = Array(sortedItems().prefix(Self.firstScreen))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: .seconds(1.5)) }
            group.addTask { @MainActor in
                await withTaskGroup(of: Void.self) { rows in
                    for item in first { rows.addTask { @MainActor in await self.hydratePreview(item) } }
                }
            }
            await group.next()
            group.cancelAll()
        }
        guard generation == token else { return }
        isDiscovering = false
        publishItems()
    }

    /// Forgets what the feed showed, for signing out.
    func reset() {
        close()
        lastShown = nil
        current = [:]
        locallyReadThreads = [:]
    }

    func close() {
        if isActive, !isDiscovering { lastShown = (workspaceID, items) }
        generation = UUID()
        for item in records.values { item.cancel() }
        records = [:]
        for item in previews.values { item.cancel() }
        previews = [:]
        previewOrder = []
        shownPreviews = [:]
        client = nil
        ownUserID = nil
        subscriptions = nil
        rooms = []
        unreadByRoom = [:]
        subscriptionOrder = []
        items = []
        roomStates = []
        isLoading = false
        isDiscovering = false
        errorMessage = nil
        liveRoomCount = 0
        isActive = false
    }

    func unavailable(_ message: String) {
        close()
        errorMessage = message
    }

    /// Clears a thread's unread indicator once a read receipt succeeds, before sync echoes it back.
    func markThreadRead(roomID: String, rootID: String, eventID: String? = nil) {
        let key = ActivityService.key(roomID: roomID, eventID: rootID)
        let readEventID =
            eventID
            ?? records[roomID]?.values.first(where: { $0.rootEvent.eventId == rootID })?.latestEvent?.eventId
            ?? lastShown?.items.first(where: { $0.id == key })?.latest?.eventID
        if let readEventID { locallyReadThreads[key] = readEventID }
        if var cached = lastShown {
            var changed = false
            for index in cached.items.indices where cached.items[index].id == key && cached.items[index].isUnread {
                cached.items[index].isUnread = false
                changed = true
            }
            if changed { lastShown = cached }
        }
        guard isActive, let record = records[roomID] else { return }
        record.projected = nil
        publishItems()
        refreshReceipts(for: roomID)
    }

    /// Captures the current latest reply event ID for each known thread in `roomID`, before an async room-wide read.
    func snapshotLatestEventIDs(roomID: String) -> [String: String] {
        var result: [String: String] = [:]
        if let record = records[roomID] {
            for value in record.values {
                if let latestID = value.latestEvent?.eventId {
                    result[ActivityService.key(roomID: roomID, eventID: value.rootEvent.eventId)] = latestID
                }
            }
        } else if let cached = lastShown {
            for item in cached.items where item.roomID == roomID {
                if let latestID = item.latest?.eventID { result[item.id] = latestID }
            }
        }
        return result
    }

    /// Clears every thread's unread indicator in `roomID` once the room itself is marked read. When `snapshot` is
    /// passed, only replies known at the time the read started are marked locally read so a newer reply stays unread.
    func markRoomRead(roomID: String, snapshot: [String: String]? = nil) {
        let acknowledged = snapshot ?? snapshotLatestEventIDs(roomID: roomID)
        for (key, latestID) in acknowledged { locallyReadThreads[key] = latestID }
        if var cached = lastShown {
            var changed = false
            for index in cached.items.indices where cached.items[index].roomID == roomID {
                let item = cached.items[index]
                let covered =
                    snapshot == nil || item.latest.map { acknowledged[item.id] == $0.eventID } == true
                if covered && item.isUnread {
                    cached.items[index].isUnread = false
                    changed = true
                }
            }
            if changed { lastShown = cached }
        }
        if let record = records[roomID] { record.projected = nil }
        guard isActive, records[roomID] != nil else { return }
        publishItems()
        refreshReceipts(for: roomID)
    }

    func updateRooms(_ candidates: [ChatRoom]) {
        guard isActive else { return }
        let next = candidates.filter { ThreadFeedMapping.isInScope($0, workspaceID: workspaceID) }
            .sorted { lhs, rhs in
                if (lhs.mentions > 0) != (rhs.mentions > 0) { return lhs.mentions > 0 }
                if lhs.favorite != rhs.favorite { return lhs.favorite }
                return lhs.name == rhs.name
                    ? lhs.id < rhs.id : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        var becameRead: [String] = []
        var nextUnread: [String: UnreadSnapshot] = [:]
        nextUnread.reserveCapacity(next.count)
        for room in next {
            let current = UnreadSnapshot(
                unread: room.unread, unreadMessages: room.unreadMessages, mentions: room.mentions,
                isMarkedUnread: room.isMarkedUnread)
            if let previous = unreadByRoom[room.id], current.decreased(from: previous) {
                becameRead.append(room.id)
            }
            nextUnread[room.id] = current
        }
        unreadByRoom = nextUnread
        for roomID in becameRead { refreshReceipts(for: roomID) }
        // The room list refreshes with every unread change; the feed shows only which rooms, in order, and how.
        if next.elementsEqual(
            rooms,
            by: { $0.id == $1.id && $0.name == $1.name && $0.isDirect == $1.isDirect && $0.isPrivate == $1.isPrivate })
        {
            return
        }
        rooms = next
        for record in records.values { record.projected = nil }
        let allowed = Set(rooms.map(\.id))
        for id in records.keys.filter({ !allowed.contains($0) }) { records.removeValue(forKey: id)?.cancel() }
        let oldLiveRooms = Set(subscriptionOrder.suffix(32))
        subscriptionOrder.removeAll { !allowed.contains($0) }
        let liveRooms = Set(subscriptionOrder.suffix(32))
        liveRoomCount = liveRooms.count
        if oldLiveRooms != liveRooms, let subscriptions {
            let token = generation
            Task { [weak self] in
                guard let self, self.generation == token, Set(self.subscriptionOrder.suffix(32)) == liveRooms else {
                    return
                }
                do { try await subscriptions(liveRooms) } catch {
                    if self.generation == token {
                        self.errorMessage = "Couldn’t get live updates. \(MatrixService.safeError(error))"
                    }
                }
            }
        }
        let existing = Dictionary(uniqueKeysWithValues: roomStates.map { ($0.id, $0) })
        roomStates = rooms.map { room in
            var state = existing[room.id] ?? ThreadFeedRoomState(id: room.id, name: room.name)
            state.name = room.name
            return state
        }
        publishItems()
    }

    func checkMore() async {
        guard !isLoading, isActive else { return }
        await paginate(roomIDs: Array(roomStates.filter { $0.state == .unloaded }.prefix(8).map(\.id)))
    }

    func loadOlder(roomID: String) async {
        guard !isLoading, roomStates.contains(where: { $0.id == roomID && $0.hasMore && $0.state != .unloaded }) else {
            return
        }
        await paginate(roomIDs: [roomID])
    }

    func retry(roomID: String) async {
        guard !isLoading, roomStates.contains(where: { $0.id == roomID && $0.state == .error }) else { return }
        await paginate(roomIDs: [roomID])
    }

    /// Each thread's root, current where its preview has hydrated.
    var roots: [ChatMessage] { items.map { preview(roomID: $0.roomID, eventID: $0.root.eventID).shown($0.root) } }

    /// The current content of a thread message, for the row that shows it.
    func preview(roomID: String, eventID: String) -> ThreadPreview {
        let id = ActivityService.key(roomID: roomID, eventID: eventID)
        if let shown = shownPreviews[id] { return shown }
        // Filled without reading it: the feed's body calls this, and only the row may observe the preview.
        let content = content(id)
        let shown = ThreadPreview(state: content.state, message: content.message, error: content.error)
        shownPreviews[id] = shown
        return shown
    }

    func hydratePreview(_ item: ThreadFeedItem, retry: Bool = false) async {
        guard isActive, rooms.contains(where: { $0.id == item.roomID }) else { return }
        let token = generation
        await hydrate(roomID: item.roomID, eventID: item.root.eventID, retry: retry)
        guard generation == token, !Task.isCancelled else { return }
        if let latest = item.latest, latest.eventID != item.root.eventID {
            await hydrate(roomID: item.roomID, eventID: latest.eventID, retry: retry)
        }
    }

    private func hydrate(roomID: String, eventID: String, retry: Bool) async {
        guard let client, isActive, !Task.isCancelled else { return }
        let id = ActivityService.key(roomID: roomID, eventID: eventID)
        previewOrder.removeAll { $0 == id }
        previewOrder.append(id)
        if let existing = previews[id] {
            if retry, existing.state == .failed {
                existing.cancel()
                previews[id] = nil
            } else {
                await existing.task?.value
                return
            }
        }
        let preview = Preview()
        let token = generation
        previews[id] = preview
        while previewOrder.count > 64 {
            let removed = previewOrder.removeFirst()
            previews.removeValue(forKey: removed)?.cancel()
            show(removed)
        }
        let previewToken = preview.token
        preview.task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let room = try client.getRoom(roomId: roomID) else { throw MatrixServiceError.noRoom }
                let configuration = TimelineConfiguration(
                    focus: .event(
                        eventId: eventID, numContextEvents: 0, threadMode: .automatic(hideThreadedEvents: false)),
                    filter: .all, internalIdPrefix: nil, dateDividerMode: .daily, trackReadReceipts: .disabled,
                    reportUtds: false)
                let timeline = try await self.limit.run {
                    try await room.timelineWithConfiguration(configuration: configuration)
                }
                guard self.generation == token, self.previews[id]?.token == previewToken, !Task.isCancelled else {
                    return
                }
                preview.timeline = timeline
                let handle = await timeline.addListener(
                    listener: ThreadPreviewObserver { [weak self] revision in
                        Task { @MainActor [weak self] in
                            await self?.readPreview(
                                id: id, roomID: roomID, eventID: eventID, generation: token, previewToken: previewToken,
                                revision: revision)
                        }
                    })
                guard self.generation == token, self.previews[id]?.token == previewToken, !Task.isCancelled else {
                    handle.cancel()
                    return
                }
                preview.handle = handle
                await self.readPreview(
                    id: id, roomID: roomID, eventID: eventID, generation: token, previewToken: previewToken,
                    revision: preview.revision)
            } catch {
                guard self.generation == token, self.previews[id]?.token == previewToken, !Task.isCancelled else {
                    return
                }
                preview.state = .failed
                preview.message = nil
                preview.error = MatrixService.safeError(error)
                self.show(id)
            }
            if self.generation == token, self.previews[id]?.token == previewToken { preview.task = nil }
        }
        show(id)
        await preview.task?.value
    }

    private func readPreview(
        id: String, roomID: String, eventID: String, generation: UUID, previewToken: UUID, revision: Int
    ) async {
        guard self.generation == generation, let preview = previews[id], preview.token == previewToken,
            revision >= preview.revision, let timeline = preview.timeline
        else { return }
        preview.revision = revision
        do {
            let event = try await timeline.getEventTimelineItemByEventId(eventId: eventID)
            guard self.generation == generation, previews[id]?.token == previewToken, preview.revision == revision
            else { return }
            guard var message = MatrixMapping.message(event, roomID: roomID, ownUserID: nil) else {
                throw MatrixServiceError.request("This message preview is unavailable.")
            }
            if message.formattedBody?.localizedCaseInsensitiveContains("data-mx-spoiler") == true {
                message.body = "[Spoiler hidden]"
            }
            preview.message = message
            preview.state = .ready
            preview.error = nil
            current[id] = message
        } catch {
            guard self.generation == generation, previews[id]?.token == previewToken, preview.revision == revision
            else { return }
            preview.message = nil
            preview.state = .failed
            preview.error = MatrixService.safeError(error)
        }
        show(id)
    }

    private func record(for roomID: String, client: Client) throws -> Record {
        if let record = records[roomID] { return record }
        guard let room = try client.getRoom(roomId: roomID), room.membership() == .joined else {
            throw MatrixServiceError.noRoom
        }
        let record = Record(room: room, service: room.threadListService())
        let token = generation
        records[roomID] = record
        let recordToken = record.token
        record.handles.append(
            record.service.subscribeToItemsUpdates(
                listener: ThreadFeedItemsObserver { [weak self] values, revision in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, let current = self.records[roomID],
                            current.token == recordToken, revision > current.revision
                        else { return }
                        current.revision = revision
                        current.values = values
                        if !self.isDiscovering { self.refreshReceipts(for: roomID) }
                        self.publishSoon()
                    }
                }))
        record.handles.append(
            record.service.subscribeToPaginationStateUpdates(
                listener: ThreadFeedPaginationObserver { [weak self] state, revision in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, let current = self.records[roomID],
                            current.token == recordToken, revision > current.paginationRevision
                        else { return }
                        current.paginationRevision = revision
                        if case .idle(let endReached) = state { self.update(roomID) { $0.hasMore = !endReached } }
                    }
                }))
        return record
    }

    private func refreshReceipts(for roomID: String) {
        guard isActive, let userID = ownUserID, let record = records[roomID] else { return }
        record.receiptTask?.cancel()
        record.receiptRevision += 1
        let token = generation
        let recordToken = record.token
        let revision = record.receiptRevision
        let room = record.room
        let values = record.values
        record.receiptTask = Task { [weak self] in
            let receipts = await Self.loadReceipts(room: room, values: values, ownUserID: userID)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == token, let current = self.records[roomID],
                    current.token == recordToken, current.receiptRevision == revision
                else { return }
                current.receiptTask = nil
                current.unthreadedReceipt = receipts.unthreaded
                current.threadReceipts = receipts.threads
                current.projected = nil
                self.publishSoon()
            }
        }
    }

    private nonisolated static func loadBestReceipt(
        room: Room, thread: ReceiptThread, userID: String
    ) async -> UserReceipt? {
        let publicReceipt = try? await room.loadUserReceipt(receiptType: .read, thread: thread, userId: userID)
        let privateReceipt = try? await room.loadUserReceipt(receiptType: .readPrivate, thread: thread, userId: userID)
        guard let publicReceipt else { return privateReceipt }
        guard let privateReceipt else { return publicReceipt }
        let publicTime = publicReceipt.receipt.timestamp ?? 0
        let privateTime = privateReceipt.receipt.timestamp ?? 0
        return privateTime > publicTime ? privateReceipt : publicReceipt
    }

    private nonisolated static func loadReceipts(
        room: Room, values: [ThreadListItem], ownUserID: String?
    ) async -> (unthreaded: UserReceipt?, threads: [String: UserReceipt]) {
        guard let ownUserID, !values.isEmpty else { return (nil, [:]) }
        let unthreaded = await loadBestReceipt(room: room, thread: .unthreaded, userID: ownUserID)
        var threads: [String: UserReceipt] = [:]
        for value in values {
            if Task.isCancelled { return (unthreaded, threads) }
            guard let latest = value.latestEvent, !latest.isOwn, latest.sender != ownUserID,
                !ThreadFeedMapping.isRead(latest, by: unthreaded)
            else { continue }
            let rootID = value.rootEvent.eventId
            guard threads[rootID] == nil else { continue }
            let thread = ReceiptThread.thread(threadRootEventId: rootID)
            let publicReceipt = try? await room.loadUserReceipt(receiptType: .read, thread: thread, userId: ownUserID)
            if ThreadFeedMapping.isRead(latest, by: publicReceipt) {
                threads[rootID] = publicReceipt
            } else if let privateReceipt = try? await room.loadUserReceipt(
                receiptType: .readPrivate, thread: thread, userId: ownUserID)
            {
                threads[rootID] = privateReceipt
            } else if let publicReceipt {
                threads[rootID] = publicReceipt
            }
        }
        return (unthreaded, threads)
    }

    private func paginate(roomIDs: [String]) async {
        guard let client, isActive, !roomIDs.isEmpty else { return }
        let token = generation
        isLoading = true
        errorMessage = nil
        defer { if generation == token { isLoading = false } }
        var requests: [(String, Room, ThreadListService, Int, Int)] = []
        for roomID in roomIDs {
            do {
                let record = try record(for: roomID, client: client)
                requests.append((roomID, record.room, record.service, record.revision, record.receiptRevision))
                update(roomID) {
                    $0.state = .loading
                    $0.errorMessage = nil
                }
                subscriptionOrder.removeAll { $0 == roomID }
                subscriptionOrder.append(roomID)
            } catch {
                update(roomID) {
                    $0.state = .error
                    $0.errorMessage = MatrixService.safeError(error)
                }
            }
        }
        let liveRooms = Set(subscriptionOrder.suffix(32))
        liveRoomCount = liveRooms.count
        do { try await subscriptions?(liveRooms) } catch {
            if generation == token {
                errorMessage = "Couldn’t get live updates. \(MatrixService.safeError(error))"
            }
        }
        guard generation == token, !Task.isCancelled else { return }
        let limit = limit
        let userID = ownUserID
        await withTaskGroup(
            of: (
                String, String?, [ThreadListItem], (unthreaded: UserReceipt?, threads: [String: UserReceipt]), Int, Int
            )
            .self
        ) { group in
            var cursor = 0
            func addNext() {
                guard cursor < requests.count else { return }
                let (id, room, service, startRevision, startReceiptRevision) = requests[cursor]
                cursor += 1
                group.addTask {
                    let failure: String?
                    do {
                        try await limit.run { try await service.paginate() }
                        failure = nil
                    } catch { failure = await MatrixService.safeError(error) }
                    let values = service.items()
                    let receipts = await Self.loadReceipts(room: room, values: values, ownUserID: userID)
                    return (id, failure, values, receipts, startRevision, startReceiptRevision)
                }
            }
            addNext()
            addNext()
            for await (roomID, failure, values, receipts, startRevision, startReceiptRevision) in group {
                guard generation == token, !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                if let record = records[roomID] {
                    // Only apply the snapshot when no newer live listener callback landed while receipts loaded.
                    if record.revision == startRevision {
                        record.values = values
                        if record.receiptRevision == startReceiptRevision {
                            record.unthreadedReceipt = receipts.unthreaded
                            record.threadReceipts = receipts.threads
                        }
                    } else if record.receiptRevision == startReceiptRevision {
                        refreshReceipts(for: roomID)
                    }
                    update(roomID) {
                        $0.state = failure == nil ? .ready : .error
                        $0.errorMessage = failure
                        if case .idle(let endReached) = record.service.paginationState() { $0.hasMore = !endReached }
                    }
                    publishItems()
                }
                addNext()
            }
        }
    }

    private func update(_ roomID: String, _ change: (inout ThreadFeedRoomState) -> Void) {
        guard let index = roomStates.firstIndex(where: { $0.id == roomID }) else { return }
        change(&roomStates[index])
    }

    private func publishItems() {
        guard !isDiscovering else { return }
        // Rooms report their thread lists again and again as sync runs; an unchanged list must not redraw the feed.
        let next = sortedItems()
        if next != items { items = next }
    }

    /// Rooms report their thread lists in bursts as sync runs; the feed sorts once for the whole burst.
    private func publishSoon() {
        guard !publishPending else { return }
        publishPending = true
        let token = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.publishPending = false
            if self.generation == token { self.publishItems() }
        }
    }

    private func sortedItems() -> [ThreadFeedItem] {
        let all = rooms.flatMap { room -> [ThreadFeedItem] in
            guard let record = records[room.id] else { return [] }
            if let projected = record.projected { return projected }
            let projected = ThreadFeedMapping.project(
                record.values, room: room, ownUserID: ownUserID, threadReceipts: record.threadReceipts,
                unthreadedReceipt: record.unthreadedReceipt, locallyRead: locallyReadThreads)
            record.projected = projected
            return projected
        }
        // Sorted by key: comparing the items themselves copies two messages per comparison, on every room's update.
        return all.indices.map { (date: all[$0].lastActivityAt, id: all[$0].id, index: $0) }
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
            .map { all[$0.index] }
    }

    /// Copies a message's preview to the row showing it, if one does.
    private func show(_ id: String) {
        guard let shown = shownPreviews[id] else { return }
        let content = content(id)
        if shown.state != content.state { shown.state = content.state }
        if shown.message != content.message { shown.message = content.message }
        if shown.error != content.error { shown.error = content.error }
    }

    /// A message's live preview, else what it last read as, so a row never falls back to the text as first sent.
    private func content(_ id: String) -> (state: ThreadPreview.State, message: ChatMessage?, error: String?) {
        let preview = previews[id]
        if preview?.state == .ready { return (.ready, preview?.message, nil) }
        if let message = current[id] { return (.ready, message, nil) }
        return (preview?.state ?? .snapshot, nil, preview?.error)
    }

    static func placeholder(_ message: ChatMessage, failed: Bool) -> ChatMessage {
        var result = message
        result.body = failed ? "Preview unavailable. Open the thread to read this message." : "Loading current preview…"
        result.formattedBody = nil
        result.attachment = nil
        result.isEdited = false
        result.isRedacted = false
        result.kind = "unavailable"
        return result
    }
}
