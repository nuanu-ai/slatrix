package ai.nuanu.slatrix.core

/** How the Pinned messages page lists a conversation's pins, as Slack does; the cases are in spec/pinned-messages.json. */
object PinOrder {
    /** The SDK loads only a room's most recently pinned messages, this many. */
    const val SDK_LIMIT = 128

    /**
     * [items] that [pinned], the room's pinned events in the order they were pinned, still holds, each once and the
     * most recently pinned first; one pinned twice counts where it was pinned last.
     */
    fun <T> arrange(pinned: List<String>, items: List<T>, id: (T) -> String?): List<T> {
        val place = HashMap<String, Int>()
        pinned.forEachIndexed { index, event -> place[event] = index }
        return items.mapNotNull { item -> id(item)?.let { event -> place[event]?.let { Triple(event, it, item) } } }
            .distinctBy { it.first }.sortedByDescending { it.second }.map { it.third }
    }

    /** What a room past the SDK's limit says under its pins. */
    fun note(total: Int): String? = if (total > SDK_LIMIT) "Showing the $SDK_LIMIT most recent of $total pinned messages." else null
}
