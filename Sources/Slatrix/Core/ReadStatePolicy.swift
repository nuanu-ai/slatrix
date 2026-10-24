import Foundation

struct ReadStateContext: Equatable {
    var accountID: String?
    var sessionGeneration: UUID?
    var timelineGeneration: UUID?
    var roomID: String
    var selectedRoomID: String?
    var latestVisibleEventID: String?
    var isPreview = false
    var isJoined = false
    var isMainTimeline = false
    var isLiveTimeline = false
    var isAtBottom = false
    var isWindowActive = false
    var isWindowVisible = false
    var isWindowUnoccluded = false
    var hasModal = false
}

struct ReadReceiptTarget: Equatable, Hashable {
    let accountID: String
    let sessionGeneration: UUID
    let timelineGeneration: UUID
    let roomID: String
    let eventID: String
}

private struct ReadStateVisit: Equatable {
    let accountID: String
    let sessionGeneration: UUID
    let timelineGeneration: UUID
    let roomID: String

    init?(_ context: ReadStateContext) {
        guard let account = context.accountID, let session = context.sessionGeneration,
            let timeline = context.timelineGeneration
        else { return nil }
        accountID = account
        sessionGeneration = session
        timelineGeneration = timeline
        roomID = context.roomID
    }
}

/// Arm before requesting Mark unread, so an already-visible bottom cannot immediately clear it.
struct ReadStateHold: Equatable {
    private var heldVisit: ReadStateVisit?

    mutating func markUnread(_ context: ReadStateContext) {
        guard !context.isPreview, context.isJoined, context.roomID == context.selectedRoomID,
            let visit = ReadStateVisit(context)
        else { return }
        heldVisit = visit
    }

    mutating func observe(_ context: ReadStateContext) {
        guard let heldVisit else { return }
        if ReadStateVisit(context) != heldVisit || context.selectedRoomID != heldVisit.roomID {
            self.heldVisit = nil
        }
    }

    mutating func clearForExplicitRead(_ context: ReadStateContext) {
        guard let heldVisit, heldVisit.accountID == context.accountID,
            heldVisit.sessionGeneration == context.sessionGeneration, heldVisit.roomID == context.roomID
        else { return }
        self.heldVisit = nil
    }

    func blocks(_ context: ReadStateContext) -> Bool {
        guard let heldVisit else { return false }
        return heldVisit == ReadStateVisit(context)
    }
}

enum ReadStatePolicy {
    static func automaticTarget(_ context: ReadStateContext, hold: ReadStateHold = ReadStateHold())
        -> ReadReceiptTarget?
    {
        guard !context.isPreview, context.isJoined, context.isMainTimeline, context.isLiveTimeline,
            context.isAtBottom, context.isWindowActive, context.isWindowVisible, context.isWindowUnoccluded,
            !context.hasModal, context.roomID == context.selectedRoomID, !hold.blocks(context),
            let account = context.accountID, valid(account, prefix: "@"), account.contains(":"),
            valid(context.roomID, prefix: "!"), let eventID = context.latestVisibleEventID, valid(eventID, prefix: "$"),
            let session = context.sessionGeneration, let timeline = context.timelineGeneration
        else { return nil }
        return ReadReceiptTarget(
            accountID: account, sessionGeneration: session, timelineGeneration: timeline, roomID: context.roomID,
            eventID: eventID)
    }

    /// Recheck immediately before SDK submission; an old task cannot acknowledge a replacement view/session.
    static func isCurrent(
        _ target: ReadReceiptTarget, in context: ReadStateContext, hold: ReadStateHold = ReadStateHold()
    ) -> Bool {
        automaticTarget(context, hold: hold) == target
    }

    private static func valid(_ value: String, prefix: String) -> Bool { MatrixID.isValid(value, sigil: prefix) }
}
