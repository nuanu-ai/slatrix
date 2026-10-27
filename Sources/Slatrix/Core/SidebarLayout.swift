import Foundation

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

    // Keep the workspace rail, resize handle, conversation, and outer inset usable.
    private static let reserved: CGFloat = 70 + handleWidth + 360 + 5
    static let handleWidth: CGFloat = 6
    static let minimumPaneWidth: CGFloat = 280
    static let maximumPaneWidth: CGFloat = 720

    /// The thread or details pane width at 100% zoom: the dragged width, or the pane's ideal one, narrowed to what
    /// fits beside the narrowest sidebar and the reservation. Nil when even the minimum does not fit, so the pane
    /// covers the conversation instead, as Slack does in a narrow window.
    static func paneWidth(preferred: CGFloat, ideal: CGFloat, availableWidth: CGFloat) -> CGFloat? {
        let space = availableWidth - reserved - minimumWidth - handleWidth
        guard space.isFinite, space >= minimumPaneWidth else { return nil }
        let wanted =
            preferred.isFinite && preferred > 0 ? min(max(preferred, minimumPaneWidth), maximumPaneWidth) : ideal
        return min(wanted, space)
    }

    /// The conversations a section lists.
    static func sectionRooms(_ rooms: [ChatRoom], collapsed: Bool, selectedID: String?) -> [ChatRoom] {
        collapsed ? [] : rooms
    }
}
