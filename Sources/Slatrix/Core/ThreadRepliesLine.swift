import Foundation

/// The line under a thread's root in the thread pane, "1 reply" or "5 replies"; the cases are in
/// spec/thread-replies-line.json.
enum ThreadRepliesLine {
    /// The count, nil for no line. Loaded to its root, the thread's own replies say it: those sent or still sending, as
    /// the server's count leaves out deleted ones. Before that, the count its root carries in the conversation now,
    /// else the one the pane was opened with.
    static func count(
        loadedToRoot: Bool, replies: some Sequence<ChatMessage>, rootSummary: Int?, openedWith: Int?
    ) -> Int? {
        let count =
            loadedToRoot
            ? replies.count { $0.sendState != "failed" && !$0.isRedacted } : rootSummary ?? openedWith ?? 0
        return count > 0 ? count : nil
    }
}
