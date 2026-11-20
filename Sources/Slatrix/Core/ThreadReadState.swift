import Foundation

struct ThreadReadIdentity: Hashable {
    let accountID: String
    let sessionID: UUID
    let roomID: String
    let timelineID: UUID
    let rootID: String
    let threadSelectionID: UUID
    let presentationID: UUID
}
struct ThreadReadReceiptTarget: Hashable {
    let identity: ThreadReadIdentity
    let eventID: String
}
struct ThreadReadContext: Equatable {
    var identity: ThreadReadIdentity?
    var eventID: String?
    var isPresented = false
    var isReady = false
    /// Its newest message from the server is at or before the newest in view.
    var isAtBottom = false
    var isWindowActive = false
    var isWindowVisible = false
    var isWindowUnoccluded = false
    var hasModal = false
    /// Something lies over the thread: the media viewer or a dialog.
    var isCovered = false
    var manualUnreadHeld = false
}

enum ThreadReadPolicy {
    /// The thread is shown: open and ready, in a window that can read, with nothing over it.
    static func isShown(_ context: ThreadReadContext) -> Bool {
        context.identity != nil && context.isPresented && context.isReady && context.isWindowActive
            && context.isWindowVisible && context.isWindowUnoccluded && !context.hasModal && !context.isCovered
    }
    static func target(_ context: ThreadReadContext) -> ThreadReadReceiptTarget? {
        guard let identity = context.identity, isShown(context), context.isAtBottom, !context.manualUnreadHeld,
            identity.accountID.hasPrefix("@"), identity.accountID.contains(":"), identity.roomID.hasPrefix("!"),
            UnreadNavigation.isRemoteEventID(identity.rootID),
            let event = context.eventID, UnreadNavigation.isRemoteEventID(event)
        else { return nil }
        return ThreadReadReceiptTarget(identity: identity, eventID: event)
    }
    static func isCurrent(_ target: ThreadReadReceiptTarget, in context: ThreadReadContext) -> Bool {
        self.target(context) == target
    }
}
