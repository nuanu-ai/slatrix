package ai.nuanu.slatrix.core

import android.content.Context
import androidx.core.content.edit
import org.json.JSONArray

/** Your recent searches, newest first, as `spec/recent-searches.json` keeps them. */
object RecentSearches {
    private const val Limit = 10

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

/** An account's recent searches on this device, kept out of backups with the rest of the app's data. */
class RecentSearchStore(context: Context, private val userId: String) {
    private val values = context.getSharedPreferences("recent-searches", Context.MODE_PRIVATE)

    var recents: List<String>
        get() = values.getString(userId, null)?.let { stored ->
            runCatching { JSONArray(stored).let { array -> List(array.length()) { array.getString(it) } } }.getOrNull()
        }.orEmpty()
        set(value) { values.edit { if (value.isEmpty()) remove(userId) else putString(userId, JSONArray(value).toString()) } }
}
