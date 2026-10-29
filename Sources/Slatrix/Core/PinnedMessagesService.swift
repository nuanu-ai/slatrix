import Foundation
import MatrixRustSDK
import Observation

// The pinned-events focus fetches validated related events itself. This SDK caps it at
// the 128 most recently pinned IDs; backwards/forwards pagination is unsupported.
enum PinnedMessagesMapping {
    static let sdkLimit = 128
    static let pageSize = 30

    /// The items the room still pins, each once, the most recently pinned first, as Slack lists them; one pinned twice
    /// counts where it was pinned last. The cases are in spec/pinned-messages.json.
    static func arrange<Item>(_ items: [Item], pinned: [String], id: (Item) -> String) -> [Item] {
        var place: [String: Int] = [:]
        for (index, event) in pinned.enumerated() { place[event] = index }
        var seen = Set<String>()
        return items.filter { place[id($0)] != nil && seen.insert(id($0)).inserted }
            .sorted { place[id($0)]! > place[id($1)]! }
    }

    static func limitNote(total: Int) -> String? {
        total > sdkLimit ? "Showing the \(sdkLimit) most recent of \(total) pinned messages." : nil
    }

    static func messages(_ items: [TimelineItem], roomID: String, pinned: [String], ownID: String?) -> [ChatMessage] {
        let messages = items.compactMap { item -> ChatMessage? in
            guard let event = item.asEvent(), event.isRemote else { return nil }
            return MatrixMapping.message(event, roomID: roomID, ownUserID: ownID)
        }
        return arrange(messages, pinned: pinned) { $0.eventID }
    }
}

private final class PinnedTimelineObserver: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TimelineItem] = []
    private var revision = 0
    let callback: @Sendable ([TimelineItem], Int) -> Void
    init(_ callback: @escaping @Sendable ([TimelineItem], Int) -> Void) { self.callback = callback }
    func onUpdate(diff: [TimelineDiff]) {
        lock.lock()
        items.apply(diff.map(\.change))
        revision += 1
        let snapshot = items
        let next = revision
        lock.unlock()
        callback(snapshot, next)
    }
}

private final class PinnedRoomObserver: RoomInfoListener, @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    let callback: @Sendable (RoomInfo, Int) -> Void
    init(_ callback: @escaping @Sendable (RoomInfo, Int) -> Void) { self.callback = callback }
    func call(roomInfo: RoomInfo) {
        lock.lock()
        revision += 1
        let next = revision
        lock.unlock()
        callback(roomInfo, next)
    }
}

@MainActor
@Observable final class PinnedMessagesService {
    private(set) var roomID: String?
    private(set) var messages: [ChatMessage] = []
    private(set) var state = "idle"
    private(set) var errorMessage: String?
    private(set) var canPinUnpin = false
    private(set) var isUpdating = false
    private(set) var totalLoaded = 0
    private(set) var totalPinned = 0
    private(set) var hasMore = false
    private(set) var coverageMessage: String?
    private(set) var pinnedEventIDs = Set<String>()
    /// The room's pinned events in the order they were pinned.
    private var pinnedOrder: [String] = []

    private var client: Client?
    private var session = UUID()
    private var scope = UUID()
    private var permissionRequest = UUID()
    private var timeline: Timeline?
    private var timelineHandle: TaskHandle?
    private var roomHandle: TaskHandle?
    private var timelineItems: [TimelineItem] = []
    private var timelineRevision = 0
    private var roomRevision = 0
    private var visibleCount = PinnedMessagesMapping.pageSize
    private var mutation: UUID?

    func attach(_ client: Client?) {
        close()
        session = UUID()
        self.client = client
        mutation = nil
        isUpdating = false
    }

    func close() {
        scope = UUID()
        permissionRequest = UUID()
        timelineHandle?.cancel()
        roomHandle?.cancel()
        timelineHandle = nil
        roomHandle = nil
        timeline = nil
        timelineItems = []
        timelineRevision = 0
        roomRevision = 0
        roomID = nil
        messages = []
        pinnedEventIDs = []
        pinnedOrder = []
        totalLoaded = 0
        totalPinned = 0
        canPinUnpin = false
        hasMore = false
        coverageMessage = nil
        errorMessage = nil
        state = "idle"
        visibleCount = PinnedMessagesMapping.pageSize
    }

    func open(roomID id: String) async {
        close()
        roomID = id
        state = "loading"
        let token = scope
        let account = session
        do {
            let (_, room) = try joinedRoom(id)
            let roomObserver = PinnedRoomObserver { [weak self] info, revision in
                Task { @MainActor [weak self] in
                    guard let self, self.session == account, self.scope == token, revision > self.roomRevision else {
                        return
                    }
                    self.roomRevision = revision
                    guard info.membership == .joined else {
                        self.close()
                        return
                    }
                    self.accept(info)
                    if let powers = info.powerLevels {
                        self.canPinUnpin = powers.canOwnUserPinUnpin()
                    } else {
                        self.canPinUnpin = false
                        await self.refreshPermissions()
                    }
                }
            }
            roomHandle = room.subscribeToRoomInfoUpdates(listener: roomObserver)
            let info = try await room.roomInfo()
            try validate(account: account, scope: token, room: room)
            if roomRevision == 0 { accept(info) }
            let powerRevision = roomRevision
            let powers = try await room.getPowerLevels()
            try validate(account: account, scope: token, room: room)
            if roomRevision == powerRevision { canPinUnpin = powers.canOwnUserPinUnpin() }
            let configuration = Self.configuration
            let created = try await room.timelineWithConfiguration(configuration: configuration)
            try validate(account: account, scope: token, room: room)
            timeline = created
            let observer = PinnedTimelineObserver { [weak self] items, revision in
                Task { @MainActor [weak self] in
                    guard let self, self.session == account, self.scope == token, revision > self.timelineRevision
                    else { return }
                    guard room.membership() == .joined else {
                        self.close()
                        return
                    }
                    self.timelineRevision = revision
                    self.timelineItems = items
                    self.publish()
                    self.state = "ready"
                }
            }
            let handle = await created.addListener(listener: observer)
            guard session == account, scope == token, !Task.isCancelled else {
                handle.cancel()
                throw CancellationError()
            }
            timelineHandle = handle

        } catch is CancellationError {
            if session == account, scope == token { close() }
        } catch {
            guard session == account, scope == token else { return }
            timelineHandle?.cancel()
            roomHandle?.cancel()
            timelineHandle = nil
            roomHandle = nil
            timeline = nil
            state = "error"
            canPinUnpin = false
            errorMessage = MatrixService.safeError(error)
        }
    }

    func retry() async { if let roomID { await open(roomID: roomID) } }

    func loadMore() {
        visibleCount += PinnedMessagesMapping.pageSize
        publish()
    }

    func refreshPermissions() async {
        guard let id = roomID else {
            canPinUnpin = false
            return
        }
        let account = session
        let token = scope
        let request = UUID()
        let revision = roomRevision
        permissionRequest = request
        canPinUnpin = false
        do {
            let (_, room) = try joinedRoom(id)
            let powers = try await room.getPowerLevels()
            try validate(account: account, scope: token, room: room)
            guard permissionRequest == request, roomRevision == revision else { return }
            canPinUnpin = powers.canOwnUserPinUnpin()
        } catch {
            guard session == account, scope == token, permissionRequest == request, roomRevision == revision else {
                return
            }
            canPinUnpin = false
            if !(error is CancellationError) { errorMessage = MatrixService.safeError(error) }
        }
    }

    func permissionToPin(roomID: String) async throws -> Bool {
        let account = session
        let token = scope
        let (_, room) = try joinedRoom(roomID)
        let powers = try await room.getPowerLevels()
        try validate(account: account, scope: token, room: room)
        return powers.canOwnUserPinUnpin()
    }

    func pin(eventID: String, roomID: String) async throws -> Bool {
        try await changePin(eventID: eventID, roomID: roomID, pin: true)
    }
    func unpin(eventID: String, roomID: String) async throws -> Bool {
        try await changePin(eventID: eventID, roomID: roomID, pin: false)
    }

    private func changePin(eventID: String, roomID id: String, pin: Bool) async throws -> Bool {
        guard eventID.hasPrefix("$"), eventID.count > 1 else {
            throw MatrixServiceError.request("Only sent messages can be pinned.")
        }
        guard mutation == nil else {
            throw MatrixServiceError.request("A pin change is already in progress. Try again when it finishes.")
        }
        let account = session
        let readScope = scope
        let operation = UUID()
        let (_, room) = try joinedRoom(id)
        mutation = operation
        isUpdating = true
        defer {
            if mutation == operation {
                mutation = nil
                isUpdating = false
            }
        }
        do {
            let powers = try await room.getPowerLevels()
            try validateMutation(account: account, operation: operation, room: room)
            guard powers.canOwnUserPinUnpin() else {
                if scope == readScope, roomID == id { canPinUnpin = false }
                throw MatrixServiceError.request("You can’t pin messages here.")
            }
            let target: Timeline
            if roomID == id, let timeline {
                target = timeline
            } else {
                target = try await room.timelineWithConfiguration(configuration: Self.configuration)
            }
            try validateMutation(account: account, operation: operation, room: room)
            let changed: Bool
            if pin {
                changed = try await target.pinEvent(eventId: eventID)
            } else {
                changed = try await target.unpinEvent(eventId: eventID)
            }
            try validateMutation(account: account, operation: operation, room: room)
            if scope == readScope, roomID == id {
                let revision = roomRevision
                let info = try await room.roomInfo()
                try validateMutation(account: account, operation: operation, room: room)
                if scope == readScope, roomID == id, revision == roomRevision { accept(info) }
            }
            return changed
        } catch {
            // A late failure can belong to an operation that was already superseded.
            try validateMutation(account: account, operation: operation, room: room)
            throw error
        }
    }

    private func joinedRoom(_ id: String) throws -> (Client, Room) {
        guard let client else { throw MatrixServiceError.signedOut }
        guard let room = try client.getRoom(roomId: id), room.membership() == .joined else {
            throw MatrixServiceError.request("Join this conversation to view or change its pins.")
        }
        return (client, room)
    }

    // A pin change belongs to its account and room, not to whether the Pins panel is still open.
    private func validateMutation(account: UUID, operation: UUID, room: Room) throws {
        try Task.checkCancellation()
        guard session == account, mutation == operation else { throw CancellationError() }
        guard room.membership() == .joined else {
            throw MatrixServiceError.request("You are no longer a member of this conversation.")
        }
    }

    private func validate(account: UUID, scope token: UUID, room: Room) throws {
        try Task.checkCancellation()
        guard session == account, scope == token else { throw CancellationError() }
        guard room.membership() == .joined else {
            throw MatrixServiceError.request("You are no longer a member of this conversation.")
        }
    }

    private func accept(_ info: RoomInfo) {
        pinnedOrder = info.pinnedEventIds
        pinnedEventIDs = Set(pinnedOrder)
        totalPinned = pinnedEventIDs.count
        publish()
    }

    private func publish() {
        guard let id = roomID else { return }
        let all = PinnedMessagesMapping.messages(
            timelineItems, roomID: id, pinned: pinnedOrder, ownID: try? client?.userId())
        totalLoaded = all.count
        messages = Array(all.prefix(visibleCount))
        hasMore = all.count > messages.count
        if let note = PinnedMessagesMapping.limitNote(total: totalPinned) {
            coverageMessage = note
        } else if totalLoaded < totalPinned {
            coverageMessage =
                "\(totalLoaded) of \(totalPinned) pinned messages are available. Others may still be loading or unavailable."
        } else {
            coverageMessage = nil
        }
    }

    private static var configuration: TimelineConfiguration {
        TimelineConfiguration(
            focus: .pinnedEvents, filter: .all, internalIdPrefix: nil, dateDividerMode: .daily,
            trackReadReceipts: .disabled, reportUtds: false)
    }
}
