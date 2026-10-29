package ai.nuanu.slatrix.core

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class SavedMessagesTest {
    private val context = ApplicationProvider.getApplicationContext<Application>()
    private val values = context.getSharedPreferences("saved-messages", 0)

    // capability: message.save
    @Test fun savedMessagesSurviveReopeningNewestFirstAndSavingAgainRemovesOne() {
        SavedMessageStore(context, "@alex:example.org").toggle("!design:example.org", "\$one", 1_000)
        SavedMessageStore(context, "@alex:example.org").toggle("!general:example.org", "\$two", 2_000)
        assertEquals(listOf("\$two", "\$one"), SavedMessageStore(context, "@alex:example.org").saved.map { it.eventId })

        SavedMessageStore(context, "@alex:example.org").toggle("!design:example.org", "\$one", 3_000)
        assertEquals(listOf("\$two"), SavedMessageStore(context, "@alex:example.org").saved.map { it.eventId })
        assertEquals(emptyList<SavedMessage>(), SavedMessageStore(context, "@sam:example.org").saved)
    }

    @Test fun theyKeepTheMacsFormat() {
        // As Swift's JSONEncoder writes a SavedMessageReference: savedAt in seconds since 2001.
        values.edit().putString("@alex:example.org", """[{"roomID":"!design:example.org","eventID":"${'$'}one","savedAt":783820800.5}]""").commit()
        assertEquals(SavedMessage("!design:example.org", "\$one", 1_762_128_000_500L), SavedMessageStore(context, "@alex:example.org").saved.single())

        SavedMessageStore(context, "@alex:example.org").toggle("!general:example.org", "\$two", 978_307_201_000L)
        val written = JSONArray(values.getString("@alex:example.org", null)).getJSONObject(0)
        assertEquals("!general:example.org", written.getString("roomID"))
        assertEquals("\$two", written.getString("eventID"))
        assertEquals(1.0, written.getDouble("savedAt"), 0.0)
    }

    @Test fun storedListsThatBreakTheMacsRulesAreDroppedWhole() {
        for (stored in listOf(
            """[{"roomID":"design","eventID":"${'$'}one","savedAt":1}]""",
            """[{"roomID":"!design:example.org","eventID":"one","savedAt":1}]""",
            """[{"roomID":"!design:example.org","eventID":"${'$'}one","savedAt":1},{"roomID":"!design:example.org","eventID":"${'$'}one","savedAt":2}]""",
            "not a list",
        )) {
            values.edit().putString("@alex:example.org", stored).commit()
            assertEquals(stored, emptyList<SavedMessage>(), SavedMessageStore(context, "@alex:example.org").saved)
        }
    }
}
