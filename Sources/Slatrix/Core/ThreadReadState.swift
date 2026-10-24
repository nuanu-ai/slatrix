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
    var isAtBottom = false
    var isWindowActive = false
    var isWindowVisible = false
    var isWindowUnoccluded = false
    var hasModal = false
    var manualUnreadHeld = false
}

enum ThreadReadPolicy {
    static func target(_ context: ThreadReadContext) -> ThreadReadReceiptTarget? {
        guard let identity = context.identity, context.isPresented, context.isReady,
            context.isAtBottom, context.isWindowActive, context.isWindowVisible, context.isWindowUnoccluded,
            !context.hasModal, !context.manualUnreadHeld,
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

/// Geometry callbacks keep the identity of their originating view. A late
/// disappearance from an old pane must not clear a newer pane's bottom sample.
struct ThreadReadViewport {
    private var current: ThreadReadIdentity?
    private var bottom: ThreadReadIdentity?
    mutating func observe(_ identity: ThreadReadIdentity?) {
        if current != identity {
            current = identity
            bottom = nil
        }
    }
    mutating func record(_ visible: Bool, from identity: ThreadReadIdentity?, current: ThreadReadIdentity?) {
        guard let identity, identity == current else { return }
        observe(current)
        if visible { bottom = identity } else if bottom == identity { bottom = nil }
    }
    func isAtBottom(_ identity: ThreadReadIdentity?) -> Bool {
        identity != nil && identity == current && identity == bottom
    }
}
