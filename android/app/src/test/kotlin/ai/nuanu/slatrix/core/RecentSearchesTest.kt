package ai.nuanu.slatrix.core

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class RecentSearchesTest {
    private val context = ApplicationProvider.getApplicationContext<Application>()

    // capability: search.recent
    @Test fun recentSearchesSurviveReopeningAndBelongToTheirAccount() {
        RecentSearchStore(context, "@alex:example.org").add("launch plan")
        RecentSearchStore(context, "@alex:example.org").add("budget")
        assertEquals(listOf("budget", "launch plan"), RecentSearchStore(context, "@alex:example.org").recents)
        assertEquals(emptyList<String>(), RecentSearchStore(context, "@sam:example.org").recents)
    }

    @Test fun aSearchTooLongToKeepLeavesTheOthers() {
        RecentSearchStore(context, "@alex:example.org").add("budget")
        RecentSearchStore(context, "@alex:example.org").add("x".repeat(1_025))
        assertEquals(listOf("budget"), RecentSearchStore(context, "@alex:example.org").recents)
    }

    @Test fun storedSearchesThatBreakTheRulesAreDropped() {
        val values = context.getSharedPreferences("recent-searches", 0)
        values.edit().putString("@alex:example.org", """["budget", "${"x".repeat(1_025)}"]""").commit()
        assertEquals(emptyList<String>(), RecentSearchStore(context, "@alex:example.org").recents)
        values.edit().putString("@alex:example.org", "not a list").commit()
        assertEquals(emptyList<String>(), RecentSearchStore(context, "@alex:example.org").recents)
    }
}
