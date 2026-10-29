package ai.nuanu.slatrix.core

import java.text.Normalizer

/** A room member as the Matrix spec names their [membership]: "join", "invite", "leave" or "ban". */
data class MentionPerson(val id: String, val name: String, val membership: String = "join")

sealed interface MentionCandidate {
    data class Member(val person: MentionPerson) : MentionCandidate
    data object Room : MentionCandidate
}

/** The @ and the query after it, `start until end` in the composer's text, and who it names, best first. */
data class MentionSuggestions(val start: Int, val end: Int, val candidates: List<MentionCandidate>)

/** Slack's @ autocomplete, as on the Mac; the cases are in spec/mention-search.json. */
object MentionSearch {
    /**
     * [before] is everything before the caret; [recentSenders] the conversation's senders, latest first; [offersRoom]
     * whether your power level lets you notify the room. Null when the caret isn't in a query that names anyone, so
     * typing on after a finished name is left alone.
     */
    fun suggestions(before: String, members: List<MentionPerson>, recentSenders: List<String>, offersRoom: Boolean): MentionSuggestions? {
        val at = before.lastIndexOf('@')
        if (at < 0 || (at > 0 && !before[at - 1].isWhitespace())) return null
        val query = before.substring(at + 1)
        if (query.firstOrNull()?.isWhitespace() == true || query.any { it == '\n' || it == '\r' }) return null
        val folded = fold(query)
        val recency = HashMap<String, Int>()
        recentSenders.forEachIndexed { index, id -> recency.putIfAbsent(id, index) }
        val people = members.filter { it.membership == "join" || it.membership == "invite" }
            .mapNotNull { member -> rank(folded, member)?.let { it to member } }
            .sortedWith(compareBy<Pair<Int, MentionPerson>> { it.first }.thenBy { it.second.membership != "join" }
                .thenBy { recency[it.second.id] ?: Int.MAX_VALUE }.thenBy { fold(it.second.name) }.thenBy { it.second.id })
            .map { MentionCandidate.Member(it.second) }
        val room = offersRoom && listOf("room", "channel", "here").any { it.startsWith(folded) }
        val candidates = people + if (room) listOf(MentionCandidate.Room) else emptyList()
        return if (candidates.isEmpty()) null else MentionSuggestions(at, before.length, candidates)
    }

    /** 0: the name starts with the query; 1: a later word does; 2: the user ID does; 3: it's anywhere in either. */
    private fun rank(query: String, member: MentionPerson): Int? {
        val name = fold(member.name)
        if (name.startsWith(query)) return 0
        if ((1 until name.length).any { !name[it - 1].isLetterOrDigit() && name.startsWith(query, it) }) return 1
        val localpart = fold(member.id.removePrefix("@").substringBefore(':'))
        if (localpart.startsWith(query)) return 2
        // Across a space only whole words count, so typing on after a mention doesn't keep matching. The server name
        // is left out: everyone on it would match.
        if (' ' !in query && (query in name || query in localpart)) return 3
        return null
    }

    private val marks = Regex("\\p{Mn}+")
    private fun fold(text: String) = marks.replace(Normalizer.normalize(text, Normalizer.Form.NFD), "").lowercase()
}

/** Who the composer can mention here, and whether your power level lets you notify the whole room. */
data class MentionPeople(val members: List<MentionPerson>, val offersRoom: Boolean)

/** A mention pill in the composer's text: `start until end` reads "@Name" and names [userId]. */
data class ComposerMention(val start: Int, val end: Int, val userId: String)

/** The pills after the text went from [old] to [new]; a pill the change touches turns back into plain text. */
internal fun List<ComposerMention>.after(old: String, new: String): List<ComposerMention> {
    if (isEmpty()) return this
    val prefix = old.commonPrefixWith(new).length
    val changedEnd = old.length - old.substring(prefix).commonSuffixWith(new.substring(prefix)).length
    val shift = new.length - old.length
    return mapNotNull {
        when {
            it.end <= prefix -> it
            it.start >= changedEnd -> it.copy(start = it.start + shift, end = it.end + shift)
            else -> null
        }
    }
}
