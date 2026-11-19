import Foundation

/// The conversation's one column, in points at 100% zoom: the header's title and buttons, the messages and the
/// composer all keep between its edges, the avatars' left edge and the end of the text.
enum ConversationGrid {
    /// A conversation's rows stop at this width, centered in a wider pane; a thread's rows fill its pane.
    static let rowWidth: CGFloat = 744
    /// From a row's edge to the avatar, and from the end of the text to the row's other edge.
    static func inset(thread: Bool) -> CGFloat { thread ? 16 : 20 }
    /// Between the avatar and the text: a thread's pane is narrow, so its rows give the text more of it.
    static func gap(thread: Bool) -> CGFloat { thread ? 8 : 12 }

    /// The column's edges in a pane `width` wide. Where the window buttons and the sidebar's button lead the toolbar,
    /// up to `chrome`, the title starts after them instead.
    static func column(width: CGFloat, thread: Bool, chrome: CGFloat = 0) -> (leading: CGFloat, trailing: CGFloat) {
        let margin = (width - (thread ? width : min(width, rowWidth))) / 2 + inset(thread: thread)
        return (max(margin, chrome), width - margin)
    }
}
