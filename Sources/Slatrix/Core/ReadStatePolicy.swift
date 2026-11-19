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
    /// Something lies over the conversation: a pane in its place, the media viewer or a dialog.
    var isCovered = false
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

/// A message is either seen or announced: read receipts go only for what is on screen, and a desktop notification
/// holds back only for it.
enum ReadStatePolicy {
    /// The conversation is on screen: the one shown, live and at its newest rows, in a window that can read, with
    /// nothing over it.
    static func isOnScreen(_ context: ReadStateContext) -> Bool {
        context.isJoined && context.isMainTimeline && context.isLiveTimeline && context.isAtBottom
            && context.isWindowActive && context.isWindowVisible && context.isWindowUnoccluded && !context.hasModal
            && !context.isCovered && context.roomID == context.selectedRoomID
    }

    /// Whether a message in `roomID`, in the thread on `threadRootID` when it has one, is on screen.
    static func isOnScreen(
        roomID: String, threadRootID: String?, conversation: ReadStateContext, thread: ThreadReadContext
    ) -> Bool {
        guard let threadRootID else { return conversation.roomID == roomID && isOnScreen(conversation) }
        return thread.identity?.roomID == roomID && thread.identity?.rootID == threadRootID
            && ThreadReadPolicy.isOnScreen(thread)
    }

    static func automaticTarget(_ context: ReadStateContext, hold: ReadStateHold = ReadStateHold())
        -> ReadReceiptTarget?
    {
        guard !context.isPreview, isOnScreen(context), !hold.blocks(context),
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

    /// Whether an open conversation's newest message counts as seen: once any part of it is on screen, so one taller
    /// than the screen reads as soon as it shows. The cases are in spec/read-state.json.
    static func isSeen(top: CGFloat, bottom: CGFloat, screenTop: CGFloat, screenBottom: CGFloat) -> Bool {
        top < screenBottom && bottom > screenTop
    }

    private static func valid(_ value: String, prefix: String) -> Bool { MatrixID.isValid(value, sigil: prefix) }
}
