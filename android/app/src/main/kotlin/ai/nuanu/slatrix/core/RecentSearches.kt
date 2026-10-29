package ai.nuanu.slatrix.core

import android.content.Context

/** Your recent searches, newest first, as `spec/recent-searches.json` keeps them. */
object RecentSearches {
    fun adding(query: String, recents: List<String>): List<String> = recents

    /** What the search field offers while [query] is typed. */
    fun offered(query: String, recents: List<String>): List<String> = emptyList()
}

/** An account's recent searches on this device. */
class RecentSearchStore(context: Context, userId: String) {
    var recents: List<String>
        get() = emptyList()
        set(value) {}
}
