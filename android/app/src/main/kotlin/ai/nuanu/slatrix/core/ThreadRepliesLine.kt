package ai.nuanu.slatrix.core

/** The line under a thread's root in the thread pane, "1 reply" or "5 replies"; the cases are in spec/thread-replies-line.json. */
object ThreadRepliesLine {
    /**
     * The count, null for no line. Loaded to its root, the thread's own replies say it: those sent or still sending, as the
     * server's count leaves out deleted ones. Before that, the count its root carries in the channel now, else the one the
     * thread was opened with.
     */
    fun count(loadedToRoot: Boolean, replies: List<ConversationMessage>, rootSummary: Int?, openedWith: Int?): Int? {
        val count = if (loadedToRoot) replies.count { it.sendState != MessageSendState.Failed && it.kind != MessageKind.Deleted }
            else rootSummary ?: openedWith ?: 0
        return count.takeIf { it > 0 }
    }
}
