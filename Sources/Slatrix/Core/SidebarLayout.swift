import Foundation

/// How the window divides its width, in points at 100% zoom: callers pass the window's width divided by the zoom, so
/// zooming in narrows things sooner. Each rule depends on that width alone, so dragging the window's edge across a
/// threshold crosses it once and nothing flickers.
enum SidebarLayout {
    static let minimumWidth: CGFloat = 220
    static let defaultWidth: CGFloat = 280
    static let maximumWidth: CGFloat = 420

    static func validatedPreferred(_ value: Double) -> CGFloat {
        guard value.isFinite, value >= Double(minimumWidth), value <= Double(maximumWidth) else { return defaultWidth }
        return CGFloat(value)
    }

    static func effective(preferred: CGFloat, availableWidth: CGFloat, inspectorWidth: CGFloat) -> CGFloat {
        let preferred = validatedPreferred(Double(preferred))
        guard availableWidth.isFinite, availableWidth >= 0, inspectorWidth.isFinite else { return minimumWidth }
        let remaining = availableWidth - max(0, inspectorWidth) - reserved
        return min(preferred, max(minimumWidth, remaining))
    }

    /// The narrowest the conversation gets beside the sidebar or a pane: the composer's toolbar on one line and
    /// about 60 characters of message, near where Slack moves a thread over the conversation.
    static let readableWidth: CGFloat = 480
    static let handleWidth: CGFloat = 6
    static let minimumPaneWidth: CGFloat = 280
    static let maximumPaneWidth: CGFloat = 720
    /// The frame around the conversation panel.
    private static let inset: CGFloat = 4
    // The workspace rail, the sidebar's divider, a readable conversation and the frame on its right.
    private static let reserved: CGFloat = 68 + handleWidth + readableWidth + inset

    /// Whether the rail and sidebar leave for a drawer: the narrowest sidebar no longer fits beside a readable
    /// conversation and, while one is open, the narrowest pane. The sidebar gives way before the pane covers the
    /// conversation.
    static func collapses(availableWidth: CGFloat, paneOpen: Bool = false) -> Bool {
        !(availableWidth >= reserved + minimumWidth + (paneOpen ? handleWidth + minimumPaneWidth : 0))
    }

    /// Whether the title bar keeps its search field, which otherwise becomes a button; below this the field would
    /// be too short for its prompt.
    static func searchFits(availableWidth: CGFloat) -> Bool { availableWidth >= 640 }

    /// The thread or details pane width: the dragged width, or the pane's ideal one, narrowed to what fits beside
    /// a readable conversation and the narrowest sidebar while it shows. Nil when even the minimum does not fit, so
    /// the pane covers the conversation instead.
    static func paneWidth(
        preferred: CGFloat, ideal: CGFloat, availableWidth: CGFloat, sidebarShown: Bool = true
    ) -> CGFloat? {
        let beside = sidebarShown ? reserved + minimumWidth : inset + readableWidth + inset
        let space = availableWidth - beside - handleWidth
        guard space >= minimumPaneWidth else { return nil }
        let wanted =
            preferred.isFinite && preferred > 0 ? min(max(preferred, minimumPaneWidth), maximumPaneWidth) : ideal
        return min(wanted, space)
    }

    /// The conversations a section lists. A collapsed one still lists the open conversation and every unread one,
    /// as Slack does.
    static func sectionRooms(_ rooms: [ChatRoom], collapsed: Bool, selectedID: String?) -> [ChatRoom] {
        collapsed ? rooms.filter { $0.id == selectedID || UnreadBadge($0) != .none } : rooms
    }
}
