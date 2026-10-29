package ai.nuanu.slatrix.core

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class UnreadBadgeTest {
    // capability: home.unread-badges
    @Test fun `room and combined badges match every shared case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/unread-badge.json").readText()).asJsonObject
        for (item in spec["badge"].asJsonArray) {
            val case = item.asJsonObject
            assertEquals(case["name"].asString, case["badge"].asString, label(UnreadBadge.forRoom(room(case["room"].asJsonObject))))
        }
        for (item in spec["combined"].asJsonArray) {
            val case = item.asJsonObject
            assertEquals(case["name"].asString, case["badge"].asString, label(UnreadBadge.combined(case["rooms"].asJsonArray.map { room(it.asJsonObject) })))
        }
    }

    private fun room(value: JsonObject) = RoomUnread(
        direct = value["direct"]?.asBoolean ?: false,
        muted = value["muted"]?.asBoolean ?: false,
        markedUnread = value["markedUnread"]?.asBoolean ?: false,
        messages = value["messages"]?.asLong ?: 0,
        notifications = value["notifications"]?.asLong ?: 0,
        mentions = value["mentions"]?.asLong ?: 0,
        membership = value["membership"]?.asString ?: "join",
        space = value["space"]?.asBoolean ?: false,
    )

    private fun label(badge: UnreadBadge): String = when (badge) {
        UnreadBadge.None -> "none"
        UnreadBadge.Bold -> "bold"
        is UnreadBadge.Count -> badge.label
    }
}
