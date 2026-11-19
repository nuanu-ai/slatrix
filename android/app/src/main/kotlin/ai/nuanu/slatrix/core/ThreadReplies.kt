package ai.nuanu.slatrix.core

/** The line under a thread's root that counts its replies, as the channel does. The cases are in spec/thread-replies.json. */
object ThreadReplies {
    /**
     * Its words, and null for no line. [count] is the root's own reply count, which can lag behind, or already include, a
     * reply of this device's, so the [replies] held that haven't failed count when they're more. A deleted reply isn't
     * one, as the server's count leaves it out.
     */
    fun divider(count: Int, replies: List<ConversationMessage>): String? =
        when (val shown = maxOf(count, replies.count { it.sendState != MessageSendState.Failed && it.kind != MessageKind.Deleted })) {
            0 -> null
            1 -> "1 reply"
            else -> "$shown replies"
        }
}
