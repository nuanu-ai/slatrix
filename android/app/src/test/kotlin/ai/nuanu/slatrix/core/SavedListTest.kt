package ai.nuanu.slatrix.core

import android.app.Application
import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import java.time.ZoneId
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

    // capability: later.complete
    // capability: later.archive
    @Test fun completingArchivingAndBringingBackChangeLaterAsInEverySharedCase() {
        for (case in cases("changing")) {
            val state = LaterState.entries.single { it.key == case["state"].asString }
            val changed = SavedList.read(case["list"].toString())
                .changing(case["room_id"].asString, case["event_id"].asString, state, case["now"].asLong)
            assertEquals(case["name"].asString, case["expected"], written(changed))
        }
    }

    // capability: later.remind
    @Test fun remindersChangeLaterAsInEverySharedCase() {
        for (case in cases("reminding")) {
            val changed = SavedList.read(case["list"].toString()).reminding(case["room_id"].asString, case["event_id"].asString,
                case["remind_at"].takeUnless { it is JsonNull }?.asLong, case["now"].asLong)
            assertEquals(case["name"].asString, case["expected"], written(changed))
        }
    }

    // capability: later.complete
    // capability: later.archive
    // capability: later.remind
    @Test fun latersTabsListAndOrderMessagesAsInEverySharedCase() {
        for (case in cases("tabs")) {
            val list = SavedList.read(case["list"].toString())
            val now = case["now"].asLong
            val shown = JsonObject().apply {
                for (state in LaterState.entries) add(state.key, ids(list.tab(state)))
                add("overdue", ids(list.tab(LaterState.IN_PROGRESS).filter { it.overdue(now) }))
            }
            assertEquals(case["name"].asString, case["expected"], shown)
        }
    }

    // capability: later.remind
    @Test fun aDeviceNotifiesOfRemindersAsInEverySharedCase() {
        for (case in cases("notifying")) {
            val reminders = JsonArray().apply {
                for (item in SavedList.read(case["list"].toString()).reminders(case["now"].asLong)) add(JsonObject().apply {
                    addProperty("room_id", item.roomId)
                    addProperty("event_id", item.eventId)
                    addProperty("remind_at", item.remindAt)
                })
            }
            assertEquals(case["name"].asString, case["expected"], reminders)
        }
    }

    // capability: later.remind
    @Test fun remindMesChoicesLandWhenEverySharedCaseSays() {
        val keys = mapOf(ReminderPreset.IN_20_MINUTES to "in_20_minutes", ReminderPreset.IN_1_HOUR to "in_1_hour",
            ReminderPreset.IN_3_HOURS to "in_3_hours", ReminderPreset.TOMORROW to "tomorrow", ReminderPreset.NEXT_WEEK to "next_week")
        for (case in cases("presets")) {
            val zone = ZoneId.of(case["time_zone"].asString)
            val times = JsonObject().apply {
                for (preset in ReminderPreset.entries) addProperty(keys.getValue(preset), preset.at(case["now"].asLong, zone))
            }
            assertEquals(case["name"].asString, case["expected"], times)
        }
    }

    private fun ids(list: List<SavedMessage>) = JsonArray().apply { list.forEach { add(it.eventId) } }

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
