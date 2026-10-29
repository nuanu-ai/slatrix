package ai.nuanu.slatrix.core

import java.text.Normalizer
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Objects

/**
 * A message search: the text, and Slack's filters. Serializes for the SDK's Tantivy query parser, whose index has
 * `body`, `sender` (an exact user ID) and `date` fields. Phrase mode is one literal: the pinned grammar reads a
 * backslash and any character after it inside double quotes.
 */
class MessageSearchQuery(text: String, val mode: Mode = Mode.Query, val roomId: String? = null, val senderId: String? = null,
    val date: SearchDate? = null) {
    enum class Mode { Query, Phrase }

    val text = text.trim()

    override fun equals(other: Any?) = other is MessageSearchQuery && text == other.text && mode == other.mode &&
        roomId == other.roomId && senderId == other.senderId && date == other.date

    override fun hashCode() = Objects.hash(text, mode, roomId, senderId, date)

    override fun toString() = "MessageSearchQuery($text, $mode, in: $roomId, from: $senderId, $date)"

    fun sdkQuery(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String? {
        val body = text.takeIf { it.isNotEmpty() }?.let { if (mode == Mode.Query) it else literal(it) }
        val filters = listOfNotNull(
            senderId?.let { "+sender:" + literal(it) },
            date?.let { "+date:[${DateTimeFormatter.ISO_INSTANT.format(it.since(now, zone))} TO *]" },
        )
        if (filters.isEmpty()) return body
        return (listOfNotNull(body?.let { if (mode == Mode.Query) "+($it)" else "+$it" }) + filters).joinToString(" ")
    }

    /** Where the index matched in [body]: it lowercases whole words split at anything not a letter or digit. */
    fun highlights(body: String): List<IntRange> {
        val operators = if (mode == Mode.Query) setOf("AND", "OR", "NOT") else emptySet()
        val terms = text.split(Separators).filter { it.isNotEmpty() && it !in operators }.map { it.lowercase() }.toSet()
        return Word.findAll(body).filter { it.value.lowercase() in terms }.map { it.range }.toList()
    }

    companion object {
        private fun literal(value: String) = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

        /**
         * Reads Slack's `in:` and `from:` out of typed text. A room is named as the list shows it, with an optional `#`
         * or `@` and quotes around spaces; a person by Matrix ID or `me`. What doesn't resolve stays in the text.
         */
        fun parse(input: String, rooms: List<RoomSummary>, me: String?): MessageSearchQuery {
            val words = ArrayDeque(input.split(Whitespace).filter { it.isNotEmpty() })
            val text = mutableListOf<String>()
            var roomId: String? = null
            var senderId: String? = null
            while (words.isNotEmpty()) {
                val word = words.removeFirst()
                val key = listOf("in:", "from:").firstOrNull { word.lowercase().startsWith(it) }
                if (key == null) {
                    text += word
                    continue
                }
                var value = word.drop(key.length)
                val consumed = mutableListOf(word)
                if (value.startsWith("\"")) {
                    while (!(value.length > 1 && value.endsWith("\"")) && words.isNotEmpty()) {
                        val next = words.removeFirst()
                        value += " $next"
                        consumed += next
                    }
                    value = value.trim('"')
                }
                if (key == "in:" && roomId == null) {
                    val name = value.trimStart('#', '@')
                    roomId = rooms.firstOrNull { it.name.equals(name, ignoreCase = true) }?.id
                    if (roomId != null) continue
                } else if (key == "from:" && senderId == null) {
                    senderId = if (value.equals("me", ignoreCase = true)) me else value.takeIf(::isUserId)
                    if (senderId != null) continue
                }
                text += consumed
            }
            return MessageSearchQuery(text.joinToString(" "), roomId = roomId, senderId = senderId)
        }

        /** An untrusted user ID: the sigil, something after it, a bounded length and no control characters. */
        private fun isUserId(value: String) =
            value.startsWith("@") && value.length > 1 && value.toByteArray().size <= 2_048 && value.none(Char::isISOControl)
    }
}

/** Slack's date filter: hits since the start of a day this far back. */
enum class SearchDate(val label: String) {
    Today("Today"), Week("Last 7 days"), Month("Last 30 days"), Year("Last 12 months");

    fun since(now: Instant, zone: ZoneId): Instant {
        val local = now.atZone(zone)
        val back = when (this) {
            Today -> local
            Week -> local.minusDays(7)
            Month -> local.minusDays(30)
            Year -> local.minusMonths(12)
        }
        return back.toLocalDate().atStartOfDay(zone).toInstant()
    }
}

/**
 * Finding a conversation by name: names that start with the query, then names with a word that does, then names that
 * contain it; the last visited first within each, then the room list's own order. Case and accents don't matter.
 */
object ConversationSearch {
    fun results(rooms: List<RoomSummary>, query: String, visited: List<String> = emptyList()): List<RoomSummary> {
        val needle = fold(query.trim().trimStart('#', '@'))
        val lastVisit = visited.withIndex().associate { (index, id) -> id to index }
        return rooms.withIndex().mapNotNull { (index, room) ->
            val recency = lastVisit[room.id]?.let { -it - 1 } ?: index
            val name = fold(room.name)
            val tier = when {
                needle.isEmpty() || name.startsWith(needle) -> 0
                name.split(Separators).any { it.startsWith(needle) } -> 1
                needle in name -> 2
                else -> return@mapNotNull null
            }
            Triple(tier, recency, room)
        }.sortedWith(compareBy({ it.first }, { it.second })).map { it.third }
    }

    private fun fold(value: String) =
        Normalizer.normalize(value, Normalizer.Form.NFD).replace(Marks, "").lowercase()
}

// Compiled once: ranking runs over every conversation on each keystroke.
private val Word = Regex("[\\p{L}\\p{N}]+")
private val Separators = Regex("[^\\p{L}\\p{N}]+")
private val Whitespace = Regex("\\s+")
private val Marks = Regex("\\p{Mn}+")
