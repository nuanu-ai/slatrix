/// What lies over the conversation and its thread. What something covers takes no input and marks nothing read, and
/// commands leave it alone.
struct Coverage: Equatable {
    /// A pane in the conversation's place, in a window too narrow for both.
    var pane = false
    var viewer = false
    var dialog = false
    var drawer = false

    /// The media viewer, a dialog and the sidebar drawer lie over the thread too.
    var thread: Bool { viewer || dialog || drawer }
    var conversation: Bool { pane || thread }
}
