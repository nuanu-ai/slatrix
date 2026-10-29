package ai.nuanu.slatrix.core

import android.content.Context
import androidx.core.content.edit
import org.json.JSONArray

/** Your recent searches, newest first, as `spec/recent-searches.json` keeps them. */
object RecentSearches {
    const val Limit = 10

    fun adding(query: String, recents: List<String>): List<String> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return recents
        return (listOf(trimmed) + recents.filterNot { it.equals(trimmed, ignoreCase = true) }).take(Limit)
    }

    /** What the search field offers while [query] is typed. */
    fun offered(query: String, recents: List<String>): List<String> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return recents.take(5)
        return recents.filter { it.contains(trimmed, ignoreCase = true) && !it.equals(trimmed, ignoreCase = true) }.take(3)
    }
}

/**
 * An account's recent searches on this device, kept out of backups with the rest of the app's data. A stored list that
 * breaks the rules, longer than the limit or with an oversized search, is dropped whole, as on the Mac.
 */
class RecentSearchStore(context: Context, private val userId: String) {
    private val values = context.getSharedPreferences("recent-searches", Context.MODE_PRIVATE)

    val recents: List<String>
        get() = values.getString(userId, null)?.let { stored ->
            runCatching { JSONArray(stored).let { array -> List(array.length()) { array.getString(it) } } }.getOrNull()
        }?.takeIf { list -> list.size <= RecentSearches.Limit && list.all { it.toByteArray().size <= 1_024 } }.orEmpty()

    /** Puts [query] first and returns the list it makes. */
    fun add(query: String): List<String> =
        RecentSearches.adding(query, recents).also { values.edit { putString(userId, JSONArray(it).toString()) } }
}
