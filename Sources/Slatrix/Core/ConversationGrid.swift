import Foundation

/// The conversation's horizontal layout, in points at 100% zoom: messages, composer and jump pill span the pane
/// between its edge insets, matching Slack desktop.
enum ConversationGrid {
    /// Collection feeds (Activity, Threads, Later, Drafts, Search) cap prose and cards here on ultrawide displays.
    static let collectionWidth: CGFloat = 920
    /// From a row's edge to the avatar, and from the end of the text to the row's other edge.
    static func inset(thread: Bool) -> CGFloat { thread ? 16 : 20 }
    /// Between the avatar and the text: a thread's pane is narrow, so its rows give the text more of it.
    static func gap(thread: Bool) -> CGFloat { thread ? 8 : 12 }

    /// The column's edges in a pane `width` wide. Where the window buttons and the sidebar's button lead the toolbar,
    /// up to `chrome`, the title starts after them instead.
    static func column(width: CGFloat, thread: Bool, chrome: CGFloat = 0) -> (leading: CGFloat, trailing: CGFloat) {
        let margin = inset(thread: thread)
        return (max(margin, chrome), width - margin)
    }
}
