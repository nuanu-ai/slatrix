import CoreGraphics

/// Where a timeline's viewport sits and how it follows changes to its rows, the way Slack's message list does: it
/// opens at the newest message, stays there while new ones arrive, and otherwise keeps what you are reading still.
enum TimelineScrollPolicy {
    /// Within this distance of the end, the viewport counts as at the bottom.
    static let bottomTolerance: CGFloat = 2

    enum Position: Equatable {
        /// The end of the timeline, following new messages.
        case bottom
        /// A row kept at `offset` points from the top of the viewport (negative when its top is scrolled past), and the
        /// rows that were on screen below it at theirs, to stand in for it when it is gone or ends above its offset.
        case anchored(rowID: String, offset: CGFloat, next: [Anchor] = [])
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
        /// Empty space the viewport shows past the end of the content.
        var overshoot: CGFloat { max(0, top + height - contentHeight) }

        init(top: CGFloat, height: CGFloat, contentHeight: CGFloat) {
            self.top = top
            self.height = height
            self.contentHeight = contentHeight
        }

        /// What the reader sees of `clip`, the scroll view's bounds in content coordinates: rows passing under the
        /// header's and the composer's glass, `covered` deep at each end, can't be read.
        init(clip: CGRect, covered: (top: CGFloat, bottom: CGFloat), contentHeight: CGFloat) {
            self.init(
                top: clip.minY + covered.top, height: max(0, clip.height - covered.top - covered.bottom),
                contentHeight: contentHeight)
        }
    }

    struct Anchor: Equatable {
        var rowID: String
        var offset: CGFloat
    }

    struct RowFrame: Equatable {
        var id: String
        var top: CGFloat
        var height: CGFloat
    }

    /// The position to keep across a change of rows or viewport size. A live timeline at its end follows new
    /// messages; anything else keeps the first of `visibleRows` in place, or failing that the next that survives.
    static func position(of viewport: Viewport, live: Bool, visibleRows: @autoclosure () -> [RowFrame]) -> Position {
        if live && viewport.isAtBottom { return .bottom }
        let visibleRows = visibleRows()
        guard let row = visibleRows.first else { return .bottom }
        return .anchored(
            rowID: row.id, offset: row.top - viewport.top,
            next: visibleRows.dropFirst().map { Anchor(rowID: $0.id, offset: $0.top - viewport.top) })
    }

    /// The viewport top that puts `position` back on screen, or nil when its rows are gone.
    static func top(
        for position: Position, contentHeight: CGFloat, viewportHeight: CGFloat, frame: (String) -> RowFrame?
    ) -> CGFloat? {
        let target: CGFloat
        switch position {
        case .bottom: target = contentHeight - viewportHeight
        case .anchored:
            guard let held = held(position, viewportHeight: viewportHeight, frame: frame) else { return nil }
            target = held.row.top - held.offset
        case .centered(let id):
            guard let row = frame(id) else { return nil }
            target = row.top + row.height / 2 - viewportHeight / 2
        }
        return min(max(0, target), max(0, contentHeight - viewportHeight))
    }

    /// The row that holds an anchored position and the offset it goes back to: the anchored row, or when it is gone or
    /// would no longer show at its offset, the first row that was on screen below it and still would at its own.
    private static func held(_ position: Position, viewportHeight: CGFloat, frame: (String) -> RowFrame?) -> (
        row: RowFrame, offset: CGFloat
    )? {
        guard case .anchored(let id, let offset, let next) = position else { return nil }
        var survivor: (row: RowFrame, offset: CGFloat)?
        for anchor in [Anchor(rowID: id, offset: offset)] + next {
            guard let row = frame(anchor.rowID) else { continue }
            if anchor.offset + row.height > 0 && anchor.offset < viewportHeight { return (row, anchor.offset) }
            survivor = survivor ?? (row, anchor.offset)
        }
        // With none on screen, the first that survives still marks the place better than leaving the view where it was.
        return survivor
    }

    /// How far a change the reader didn't make moved what they were reading at `position`: their row, or the newest
    /// message they were following. Nil when it held still.
    static func jump(from position: Position, to viewport: Viewport, frame: (String) -> RowFrame?) -> CGFloat? {
        let moved: CGFloat
        switch position {
        case .bottom: moved = viewport.distanceFromBottom
        case .anchored:
            guard let held = held(position, viewportHeight: viewport.height, frame: frame) else { return nil }
            moved = held.row.top - viewport.top - held.offset
        case .centered: return nil
        }
        return abs(moved) >= 1 ? moved : nil
    }

    /// Where a timeline opens: at a linked message, else where the reader left this conversation, else the end.
    /// `startsAtUnread` puts the unread line at the top instead, when it is loaded.
    static func opening(
        focusedRowID: String?, unreadRowID: String?, startsAtUnread: Bool, remembered: Position?,
        contains: (String) -> Bool
    ) -> Position {
        if startsAtUnread, let unreadRowID, contains(unreadRowID) { return .anchored(rowID: unreadRowID, offset: 0) }
        if let focusedRowID { return .centered(rowID: focusedRowID) }
        if let remembered, case .anchored(let id, _, _) = remembered, contains(id) { return remembered }
        return .bottom
    }

    /// "Jump to recent" shows anywhere in a timeline opened at an older message, which never gets new ones. In a live
    /// timeline it shows once the reader has scrolled more than two screens from the newest message themselves: closer
    /// than that a flick gets back, and the app's own scroll to the unread line or a linked message is where the
    /// reader asked to be.
    static func showsJumpToLatest(_ viewport: Viewport, live: Bool, scrolledByReader: Bool) -> Bool {
        !live || scrolledByReader && viewport.distanceFromBottom > viewport.height * 2
    }

    /// A timeline opened at an older message turns live once the reader is at its newest message with nothing newer to
    /// load, as Slack's does. An open edit holds it back: only a timeline that holds a message can edit it.
    static func turnsLive(atBottom: Bool, live: Bool, hasNewer: Bool, editing: Bool) -> Bool {
        atBottom && !live && !hasNewer && !editing
    }

    /// History starts loading this many screens before the reader reaches an end, so a page lands before they do.
    static let historyLead: CGFloat = 3

    /// Older history loads before the reader reaches the top, so scrolling up never stops at a button.
    static func needsOlder(_ viewport: Viewport) -> Bool { viewport.top < viewport.height * historyLead }

    /// Newer history of a timeline opened at an older message loads before the reader reaches its end.
    static func needsNewer(_ viewport: Viewport) -> Bool {
        viewport.distanceFromBottom < viewport.height * historyLead
    }
}
