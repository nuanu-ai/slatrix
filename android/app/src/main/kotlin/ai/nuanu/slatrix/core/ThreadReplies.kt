package ai.nuanu.slatrix.core

/** The line under a thread's root that counts its replies. The cases are in spec/thread-replies.json. */
object ThreadReplies {
    /**
     * Its words once the thread has [loaded] back to its root, empty while the line holds its place, and null for no
     * line. [replies] are the event IDs of the messages after the root, null for one the server hasn't confirmed.
     */
    fun divider(loaded: Boolean, replies: List<String?>): String? {
        if (!loaded) return ""
        return when (val count = replies.count { it != null }) {
            0 -> null
            1 -> "1 reply"
            else -> "$count replies"
        }
    }
}
