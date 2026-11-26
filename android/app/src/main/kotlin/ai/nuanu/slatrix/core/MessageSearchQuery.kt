package ai.nuanu.slatrix.core

import java.text.Normalizer
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Objects

/**
 * A message search: the text, and Slack's filters. Serializes for the SDK's Tantivy query parser, whose index has
 * `body`, `sender` (an exact user ID) and `date` fields. Query mode requires every word (AND), expands 3+ character
 * words into exact-boosted prefix ranges so inflected forms match, supports quoted phrases and `-term` exclusions,
 * and strips raw punctuation so normal queries never fail parsing.
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
        val filters = listOfNotNull(
            senderId?.let { "+sender:" + literal(it) },
            date?.let { "+date:[${DateTimeFormatter.ISO_INSTANT.format(it.since(now, zone))} TO *]" },
        )
        if (text.isEmpty()) return filters.takeIf { it.isNotEmpty() }?.joinToString(" ")
        if (mode == Mode.Phrase) {
            val phrase = literal(text)
            if (filters.isEmpty()) return phrase
            return (listOf("+$phrase") + filters).joinToString(" ")
        }
        val parsed = tokenize(text)
        var positive = parsed.positive
        var negative = parsed.negative
        if (positive.isEmpty() && filters.isEmpty()) {
            if (negative.isNotEmpty()) {
                if (roomId != null) return null
                positive = negative
                negative = emptyList()
            } else {
                positive = listOf(literal(text))
            }
        }
        if (positive.size == 1 && negative.isEmpty() && filters.isEmpty()) return positive.first()
        return (positive.map { "+$it" } + negative.map { "-$it" } + filters).joinToString(" ")
    }

    /** Where the index matched in [body]: exact whole words for phrases, or prefix (3+ chars) / exact (1-2 chars) for unquoted query terms. */
    fun highlights(body: String): List<IntRange> {
        val exactTerms: List<String>
        val prefixTerms: List<String>
        if (mode == Mode.Phrase) {
            exactTerms = words(text)
            prefixTerms = emptyList()
        } else {
            val parsed = tokenize(text)
            if (parsed.positive.isEmpty() && roomId == null && senderId == null && date == null && parsed.negative.isNotEmpty()) {
                exactTerms = parsed.negativeExactHighlights
                prefixTerms = parsed.negativePrefixHighlights
            } else {
                exactTerms = parsed.exactHighlights
                prefixTerms = parsed.prefixHighlights
            }
        }
        if (exactTerms.isEmpty() && prefixTerms.isEmpty()) return emptyList()
        return Word.findAll(body).filter { match ->
            val lower = match.value.lowercase()
            lower in exactTerms ||
                prefixTerms.any { term ->
                    if (term.codePointCount(0, term.length) >= MinPrefixLength) lower.startsWith(term) else lower == term
                }
        }.map { it.range }.toList()
    }

    companion object {
        private const val PrefixUpperSuffix = "\uff5a"
        private const val MinPrefixLength = 3
        // Tantivy's default RemoveLongFilter drops tokens over 40 UTF-8 bytes; reserve 3 bytes for U+FF5A.
        private const val MaxPrefixUtf8Bytes = 37

        private data class Tokenized(
            val positive: List<String>,
            val negative: List<String>,
            val exactHighlights: List<String>,
            val prefixHighlights: List<String>,
            val negativeExactHighlights: List<String>,
            val negativePrefixHighlights: List<String>,
        )

        private fun tokenize(input: String): Tokenized {
            val positive = mutableListOf<String>()
            val negative = mutableListOf<String>()
            val exactHighlights = mutableListOf<String>()
            val prefixHighlights = mutableListOf<String>()
            val negativeExactHighlights = mutableListOf<String>()
            val negativePrefixHighlights = mutableListOf<String>()
            var index = 0
            while (index < input.length) {
                while (index < input.length && Character.isWhitespace(input.codePointAt(index))) {
                    index += Character.charCount(input.codePointAt(index))
                }
                if (index >= input.length) break
                var negated = false
                if (input[index] == '-' && index + 1 < input.length) {
                    val nextCp = input.codePointAt(index + 1)
                    if (nextCp == '"'.code || Character.isLetterOrDigit(nextCp)) {
                        negated = true
                        index++
                    }
                }
                if (input[index] == '"') {
                    val contentStart = index + 1
                    val scanned = scanQuoted(input, contentStart)
                    if (scanned != null) {
                        val (rawInner, afterClosing) = scanned
                        val inner = rawInner.trim()
                        index = afterClosing
                        if (inner.isNotEmpty()) {
                            val clause = literal(inner)
                            if (negated) {
                                negative += clause
                                negativeExactHighlights += words(inner)
                            } else {
                                positive += clause
                                exactHighlights += words(inner)
                            }
                        }
                        continue
                    }
                    index = contentStart
                    continue
                }
                var chunkEnd = index
                while (chunkEnd < input.length && input[chunkEnd] != '"') {
                    val cp = input.codePointAt(chunkEnd)
                    if (Character.isWhitespace(cp)) break
                    chunkEnd += Character.charCount(cp)
                }
                val chunk = input.substring(index, chunkEnd)
                index = chunkEnd
                for (raw in rawWords(chunk)) {
                    val (clause, lower, isPrefix) = wordClause(raw)
                    if (negated) {
                        negative += clause
                        if (isPrefix) negativePrefixHighlights += lower else negativeExactHighlights += lower
                    } else {
                        positive += clause
                        if (isPrefix) prefixHighlights += lower else exactHighlights += lower
                    }
                }
            }
            return Tokenized(
                positive, negative, exactHighlights, prefixHighlights, negativeExactHighlights, negativePrefixHighlights)
        }

        private fun scanQuoted(input: String, start: Int): Pair<String, Int>? {
            val sb = StringBuilder()
            var index = start
            while (index < input.length) {
                val ch = input[index]
                if (ch == '\\' && index + 1 < input.length) {
                    val escaped = input[index + 1]
                    if (escaped != '"' && escaped != '\\') sb.append(ch)
                    sb.append(escaped)
                    index += 2
                    continue
                }
                if (ch == '"') return sb.toString() to (index + 1)
                sb.append(ch)
                index++
            }
            return null
        }

        private fun rawWords(value: String): List<String> =
            value.split(Separators).filter { it.isNotEmpty() }

        private fun words(value: String): List<String> =
            rawWords(value).map { it.lowercase() }

        private fun allWordCodePoints(value: String): Boolean {
            var i = 0
            while (i < value.length) {
                val cp = value.codePointAt(i)
                if (!Character.isLetterOrDigit(cp)) return false
                i += Character.charCount(cp)
            }
            return true
        }

        private fun wordClause(raw: String): Triple<String, String, Boolean> {
            val lower = raw.lowercase()
            val lowerClean = allWordCodePoints(lower)
            if (lowerClean && lower.codePointCount(0, lower.length) >= MinPrefixLength &&
                lower.toByteArray(Charsets.UTF_8).size <= MaxPrefixUtf8Bytes) {
                return Triple("(body:$lower^2 OR body:[$lower TO $lower$PrefixUpperSuffix])", lower, true)
            }
            // Keep the original token if lowercasing introduces combining marks (e.g. Turkish İ -> i + U+0307) so
            // Tantivy's SimpleTokenizer keeps it as one token before its LowerCaser runs.
            return Triple("body:${if (lowerClean) lower else raw}", lower, false)
        }

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
                    senderId = if (value.equals("me", ignoreCase = true)) me else value.takeIf { isMatrixId(it, "@") }
                    if (senderId != null) continue
                }
                text += consumed
            }
            return MessageSearchQuery(text.joinToString(" "), roomId = roomId, senderId = senderId)
        }
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
