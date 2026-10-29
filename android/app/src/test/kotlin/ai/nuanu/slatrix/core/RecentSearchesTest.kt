package ai.nuanu.slatrix.core

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Recent searches, from the shared cases in `spec/recent-searches.json`, and where Android keeps them. */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class RecentSearchesTest {
    private val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/recent-searches.json").readText()).asJsonObject

    private fun JsonObject.strings(key: String) = this[key].asJsonArray.map { it.asString }

    @Test fun aSearchJoinsTheRecentListAsInEverySharedCase() {
        for (item in spec["adding"].asJsonArray) {
            val case = item.asJsonObject
            assertEquals(case["name"].asString, case.strings("expected"), RecentSearches.adding(case["query"].asString, case.strings("recents")))
        }
    }

    // capability: search.recent
    @Test fun theFieldOffersRecentSearchesAsInEverySharedCase() {
        for (item in spec["offered"].asJsonArray) {
            val case = item.asJsonObject
            assertEquals(case["name"].asString, case.strings("expected"), RecentSearches.offered(case["query"].asString, case.strings("recents")))
        }
    }

    // capability: search.recent
    @Test fun recentSearchesSurviveReopeningAndBelongToTheirAccount() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        RecentSearchStore(context, "@alex:example.org").recents = listOf("budget", "launch plan")
        assertEquals(listOf("budget", "launch plan"), RecentSearchStore(context, "@alex:example.org").recents)
        assertEquals(emptyList<String>(), RecentSearchStore(context, "@sam:example.org").recents)
    }
}
