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
    /// Its newest message from the server is at or before the newest in view.
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

/// What a timeline pane shows, as it last laid out.
struct PaneReport: Equatable {
    /// The newest message with any part in view.
    var newestInView: String?
    /// The newest message the pane has laid out, in view or not.
    var laidOut: String?
}

/// A message is either seen or announced. It is seen when its conversation or thread is shown, and it is in that
/// pane's timeline at or before the newest message in view: reading down to a message covers the ones before it. Read
/// receipts go for what is seen, Activity takes it off its count, and a desktop notification holds back only for it.
enum ReadStatePolicy {
    /// The conversation is shown: the one selected, in the main view, in a window that can read, with nothing over it.
    static func isShown(_ context: ReadStateContext) -> Bool {
        context.isJoined && context.isMainTimeline && context.isWindowActive && context.isWindowVisible
            && context.isWindowUnoccluded && !context.hasModal && !context.isCovered
            && context.roomID == context.selectedRoomID
    }

    /// Whether the pane for a message in `roomID`, in the thread on `threadRootID` when it has one, is shown.
    static func isShown(
        roomID: String, threadRootID: String?, conversation: ReadStateContext, thread: ThreadReadContext
    ) -> Bool {
        guard let threadRootID else { return conversation.roomID == roomID && isShown(conversation) }
        return thread.identity?.roomID == roomID && thread.identity?.rootID == threadRootID
            && ThreadReadPolicy.isShown(thread)
    }

    /// Whether `eventID` is in a timeline at or before `newestInView`, by `position`, each event's place in it.
    static func isSeen(_ eventID: String, newestInView: String?, position: (String) -> Int?) -> Bool {
        guard let newestInView, let newest = position(newestInView), let index = position(eventID) else {
            return false
        }
        return index <= newest
    }

    /// Whether the reader has seen `eventID`, whose pane is `shown` or not, with `timeline` and `report` that pane's:
    /// nil while a shown pane has yet to lay the message out.
    static func seen<Events>(
        _ eventID: String, shown: Bool, in timeline: TimelinePositions<Events>, report: PaneReport?
    ) -> Bool? {
        guard shown else { return false }
        return timeline.ask { position in
            guard isSeen(eventID, newestInView: report?.laidOut, position: position) else { return nil }
            return isSeen(eventID, newestInView: report?.newestInView, position: position)
        }
    }

    static func automaticTarget(_ context: ReadStateContext, hold: ReadStateHold = ReadStateHold())
        -> ReadReceiptTarget?
    {
        guard !context.isPreview, isShown(context), context.isLiveTimeline, context.isAtBottom, !hold.blocks(context),
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

    /// Whether a message's row is in view: once any part of it is on screen, so one taller than the screen counts as
    /// soon as it shows. The cases are in spec/read-state.json.
    static func isSeen(top: CGFloat, bottom: CGFloat, screenTop: CGFloat, screenBottom: CGFloat) -> Bool {
        top < screenBottom && bottom > screenTop
    }

    /// How long an alert for a message in a shown conversation or thread waits for the pane to lay it out.
    static let layoutDeadline: Duration = .seconds(1)

    private static func valid(_ value: String, prefix: String) -> Bool { MatrixID.isValid(value, sigil: prefix) }
}

/// Where each event sits in a timeline, for questions about what is seen. The first question searches from the end,
/// where the messages asked about usually are; a second builds an index, so asking about many costs one pass.
final class TimelinePositions<Events: BidirectionalCollection<String>> where Events.Index == Int {
    private let events: Events
    private var index: [String: Int]?
    private var asked = false

    init(_ events: Events) { self.events = events }

    /// Answers `question`, given each event's place.
    func ask<Answer>(_ question: ((String) -> Int?) -> Answer) -> Answer {
        guard asked else {
            asked = true
            return question { events.lastIndex(of: $0) }
        }
        let index = index ?? Dictionary(zip(events, events.indices), uniquingKeysWith: max)
        self.index = index
        return question { index[$0] }
    }
}
