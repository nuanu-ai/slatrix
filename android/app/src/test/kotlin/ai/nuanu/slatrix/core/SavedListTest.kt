package ai.nuanu.slatrix.core

import android.app.Application
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Later as one list per account, from the shared cases in `spec/saved-messages.json`. */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class SavedListTest {
    private val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/saved-messages.json").readText()).asJsonObject

    private fun cases(name: String) = spec[name].asJsonArray.map { it.asJsonObject }
    private fun written(list: SavedList): JsonElement = JsonParser.parseString(list.json())

    @Test fun laterReadsAccountDataAsInEverySharedCase() {
        for (case in cases("reading")) {
            assertEquals(case["name"].asString, case["expected"], written(SavedList.read(case["content"].toString())))
        }
    }

    // capability: message.save.sync
    @Test fun aDevicesLaterMergesWithTheAccountsAsInEverySharedCase() {
        for (case in cases("merging")) {
            val remote = SavedList.read(case["remote"].takeUnless { it is JsonNull }?.toString())
            val merged = SavedList.read(case["local"].toString()).merged(remote)
            assertEquals(case["name"].asString, case["expected"], written(merged))
            assertEquals(case["name"].asString, case["writes"].asBoolean, merged.content(over = remote) != null)
        }
    }

    @Test fun savingAndRemovingChangeLaterAsInEverySharedCase() {
        for (case in cases("setting")) {
            val changed = SavedList.read(case["list"].toString())
                .setting(case["room_id"].asString, case["event_id"].asString, case["saved"].asBoolean, case["now"].asLong)
            assertEquals(case["name"].asString, case["expected"], written(changed))
        }
    }

    private fun messages(count: Int) = (1..count).map { SavedMessage("!design:example.org", "\$$it", it.toLong()) }

    @Test fun laterKeepsItsNewestTenThousandSavedMessages() {
        val list = SavedList.normalized(messages(10_001), emptyList())
        assertEquals("\$10001", list.saved.first().eventId)
        assertEquals("\$2", list.saved.last().eventId)
    }

    @Test fun laterRemembersItsNewestThousandRemovalsHoweverFarAheadADevicesClockRuns() {
        val list = SavedList.normalized(listOf(SavedMessage("!general:example.org", "\$ahead", 4_000_000_000_000)), messages(1_001))
        assertEquals("\$1001", list.removed.first().eventId)
        assertEquals("\$2", list.removed.last().eventId)
    }
}
