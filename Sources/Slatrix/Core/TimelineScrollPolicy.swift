import CoreGraphics

/// Where a timeline's viewport sits and how it follows changes to its rows, the way Slack's message list does: it
/// opens at the newest message, stays there while new ones arrive, and otherwise keeps what you are reading still.
enum TimelineScrollPolicy {
    /// Within this distance of the end, the viewport counts as at the bottom.
    static let bottomTolerance: CGFloat = 2

    enum Position: Equatable {
        /// The end of the timeline, following new messages.
        case bottom
        /// A row kept at `offset` points from the top of the viewport (negative when its top is scrolled past).
        case anchored(rowID: String, offset: CGFloat)
        /// A row centred in the viewport, for opening at a linked message.
        case centered(rowID: String)
    }

    struct Viewport: Equatable {
        /// Content coordinate shown at the top of the viewport.
        var top: CGFloat
        var height: CGFloat
        var contentHeight: CGFloat
        var distanceFromBottom: CGFloat { max(0, contentHeight - top - height) }
        var isAtBottom: Bool { distanceFromBottom <= TimelineScrollPolicy.bottomTolerance }
    }

    struct RowFrame: Equatable {
        var id: String
        var top: CGFloat
        var height: CGFloat
    }

    /// The position to keep across a change of rows or viewport size. A live timeline at its end follows new
    /// messages; anything else keeps the first row visible at the top in place.
    static func position(of viewport: Viewport, live: Bool, firstVisibleRow: RowFrame?) -> Position {
        if live && viewport.isAtBottom { return .bottom }
        guard let row = firstVisibleRow else { return .bottom }
        return .anchored(rowID: row.id, offset: row.top - viewport.top)
    }

    /// The viewport top that puts `position` back on screen, or nil when its row is gone.
    static func top(
        for position: Position, contentHeight: CGFloat, viewportHeight: CGFloat, frame: (String) -> RowFrame?
    ) -> CGFloat? {
        let target: CGFloat
        switch position {
        case .bottom: target = contentHeight - viewportHeight
        case .anchored(let id, let offset):
            guard let row = frame(id) else { return nil }
            target = row.top - offset
        case .centered(let id):
            guard let row = frame(id) else { return nil }
            target = row.top + row.height / 2 - viewportHeight / 2
        }
        return min(max(0, target), max(0, contentHeight - viewportHeight))
    }

    /// Where a timeline opens: at a linked message, else where the reader left this conversation, else the end.
    /// `startsAtUnread` puts the unread line at the top instead of centring the linked message.
    static func opening(
        focusedRowID: String?, unreadRowID: String?, startsAtUnread: Bool, remembered: Position?,
        contains: (String) -> Bool
    ) -> Position {
        if let focusedRowID {
            if startsAtUnread, let unreadRowID, contains(unreadRowID) {
                return .anchored(rowID: unreadRowID, offset: 0)
            }
            return .centered(rowID: focusedRowID)
        }
        if let remembered, case .anchored(let id, _) = remembered, contains(id) { return remembered }
        return .bottom
    }

    /// "Jump to latest" shows once the reader is half a screen away from the newest message, or anywhere in a
    /// timeline opened at an older message whose end is not loaded.
    static func showsJumpToLatest(_ viewport: Viewport, live: Bool) -> Bool {
        live ? viewport.distanceFromBottom > viewport.height / 2 : !viewport.isAtBottom
    }

    /// Older history loads before the reader reaches the top, so scrolling up never stops at a button.
    static func needsOlder(_ viewport: Viewport) -> Bool { viewport.top < viewport.height }

    /// Newer history of a timeline opened at an older message loads before the reader reaches its end.
    static func needsNewer(_ viewport: Viewport) -> Bool { viewport.distanceFromBottom < viewport.height }
}
