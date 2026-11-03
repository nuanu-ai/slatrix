package ai.nuanu.slatrix.core

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import org.json.JSONObject
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
    @Test fun laterSurvivesReopeningRemovalsIncludedAndBelongsToItsAccount() {
        val list = SavedList(listOf(SavedMessage("!general:example.org", "\$two", 2_000)), listOf(SavedMessage("!design:example.org", "\$one", 3_000)))
        SavedMessageStore(context, "@alex:example.org").save(list)
        assertEquals(list, SavedMessageStore(context, "@alex:example.org").list)
        assertEquals(SavedList(), SavedMessageStore(context, "@sam:example.org").list)
    }

    @Test fun itIsKeptAsTheAccountDataContentIs() {
        SavedMessageStore(context, "@alex:example.org").save(SavedList(listOf(SavedMessage("!design:example.org", "\$one", 1_761_955_200_000))))
        assertEquals(JSONObject("""{"saved":[{"room_id":"!design:example.org","event_id":"${'$'}one","ts":1761955200000}],"removed":[]}""").toString(),
            JSONObject(values.getString("@alex:example.org", null)!!).toString())
    }

    @Test fun aListKeptBeforeLaterSyncedStillOpens() {
        // As Swift's JSONEncoder writes the Mac's SavedMessageReference: savedAt in seconds since 2001.
        values.edit().putString("@alex:example.org", """[{"roomID":"!design:example.org","eventID":"${'$'}one","savedAt":783820800.5}]""").commit()
        assertEquals(SavedList(listOf(SavedMessage("!design:example.org", "\$one", 1_762_128_000_500L))), SavedMessageStore(context, "@alex:example.org").list)
    }

    @Test fun anEarlierListThatBreaksTheMacsRulesIsDroppedWhole() {
        for (stored in listOf(
            """[{"roomID":"design","eventID":"${'$'}one","savedAt":1}]""",
            """[{"roomID":"!design:example.org","eventID":"one","savedAt":1}]""",
            """[{"roomID":"!design:example.org","eventID":"${'$'}one","savedAt":1},{"roomID":"!design:example.org","eventID":"${'$'}one","savedAt":2}]""",
            "not a list",
        )) {
            values.edit().putString("@alex:example.org", stored).commit()
            assertEquals(stored, SavedList(), SavedMessageStore(context, "@alex:example.org").list)
        }
    }
}
