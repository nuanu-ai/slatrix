import Foundation
import MatrixRustSDK

enum UnreadNavigation {
    // Counts decide whether to offer an existing anchor, never where unread
    // messages start. Explicit history/thread navigation always wins.
    static func resumeAnchor(for room: ChatRoom?, selectedRoomID: String?, explicitEventID: String?, opensThread: Bool)
        -> String?
    {
        guard let room, room.id != selectedRoomID, room.membership == "join",
            room.unreadMessages > 0 || room.unread > 0, explicitEventID == nil, !opensThread,
            let id = room.fullyReadEventID, isRemoteEventID(id)
        else { return nil }
        return id
    }

    static func isRemoteEventID(_ id: String) -> Bool {
        MatrixID.isValid(id, sigil: "$")
    }
}

enum UnreadMapping {
    /// What the unread line needs from one timeline item.
    struct Mark {
        var isReadMarker = false
        /// The remote event a reader would see, if the item is one.
        var shownEventID: String?
    }

    static func mark(virtual: VirtualTimelineItem?, event: EventTimelineItem?, shown: Bool) -> Mark {
        guard virtual != .readMarker else { return Mark(isReadMarker: true) }
        guard shown, let event, event.isRemote, case .eventId(let id) = event.eventOrTransactionId,
            UnreadNavigation.isRemoteEventID(id)
        else { return Mark() }
        return Mark(shownEventID: id)
    }

    static func firstUnreadEventID(in items: [TimelineItem], roomID: String, ownUserID: String?) -> String? {
        firstUnreadEventID(
            in: items.map { item in
                let event = item.asEvent()
                return mark(
                    virtual: item.asVirtual(), event: event,
                    shown: event.flatMap { MatrixMapping.message($0, roomID: roomID, ownUserID: ownUserID) } != nil)
            })
    }

    static func firstUnreadEventID(in marks: [Mark]) -> String? {
        guard let marker = marks.firstIndex(where: \.isReadMarker) else { return nil }
        return marks[(marker + 1)...].lazy.compactMap(\.shownEventID).first
    }
}

@MainActor
enum UnreadSDKActions {
    static func acknowledge(timeline: Timeline, eventID: String, validate: () throws -> Void) async throws {
        try validate()
        try await timeline.sendReadReceipt(receiptType: .read, eventId: eventID)
        try validate()
        try await timeline.sendReadReceipt(receiptType: .fullyRead, eventId: eventID)
        try validate()
    }

    static func markRoomRead(room: Room, validate: () throws -> Void) async throws {
        try validate()
        try await room.markAsRead(receiptType: .read)
        try validate()
        try await room.markAsRead(receiptType: .fullyRead)
        try validate()
    }

    static func loadForward(timeline: Timeline, validate: () throws -> Void) async throws -> Bool {
        try validate()
        let endReached = try await timeline.paginateForwards(numEvents: 50)
        try validate()
        return endReached
    }
}
