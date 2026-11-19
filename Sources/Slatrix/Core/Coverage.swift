/// What lies over the conversation and its thread. What something covers takes no input and marks nothing read, and
/// commands that act on what the reader can't see leave it alone, such as reacting to the last message or Escape's
/// "I've read this". A command named on a control the reader can see, or one that only changes the layout, does what
/// it says.
struct Coverage: Equatable {
    /// A pane in the conversation's place, in a window too narrow for both.
    var pane = false
    var viewer = false
    var dialog = false
    var drawer = false

    /// The media viewer, a dialog and the sidebar drawer lie over the thread too.
    var thread: Bool { viewer || dialog || drawer }
    var conversation: Bool { pane || thread }

    enum Escape: Equatable { case closeDrawer, closePane, markRead, nothing }

    /// Escape, as Slack's: it closes the nearest thing over the conversation, the open profile included, and marks the
    /// conversation read only with nothing over it. The viewer and a dialog close themselves before it gets here.
    func escape(profile: Bool, inConversation: Bool) -> Escape {
        if viewer || dialog { return .nothing }
        if drawer { return .closeDrawer }
        if profile || pane { return .closePane }
        return inConversation ? .markRead : .nothing
    }
}
