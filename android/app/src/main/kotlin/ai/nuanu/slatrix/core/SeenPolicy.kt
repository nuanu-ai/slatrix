package ai.nuanu.slatrix.core

/**
 * Who has read each of your messages. A read receipt sits on the newest message its owner has read, so it covers every
 * message above it too.
 */
object SeenPolicy {
    /** Readers of each of [me]'s messages, by message ID, from (ID, sender, receipts) oldest to newest. */
    fun readers(messages: List<Triple<String, String, List<String>>>, me: String): Map<String, List<String>> {
        val below = sortedSetOf<String>()
        val result = HashMap<String, List<String>>()
        for ((id, sender, readBy) in messages.asReversed()) {
            readBy.filterTo(below) { it != me }
            if (sender == me) result[id] = below.toList()
        }
        return result
    }
}
