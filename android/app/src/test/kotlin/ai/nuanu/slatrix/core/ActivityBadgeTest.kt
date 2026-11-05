package ai.nuanu.slatrix.core

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class ActivityBadgeTest {
    // capability: activity.badge
    @Test fun `the count matches every shared case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/activity-badge.json").readText()).asJsonObject
        for (item in spec["count"].asJsonArray) {
            val case = item.asJsonObject
            val rooms = case["rooms"].asJsonArray.map { room(it.asJsonObject) }
            val replies = case["replies"].asJsonArray.mapIndexed { index, reply -> reply(index, reply.asJsonObject) }
            assertEquals(case["name"].asString, case["count"].asInt, ActivityBadge.count(rooms, replies))
        }
    }

    private fun room(value: JsonObject) = RoomUnread(mentions = value["mentions"]?.asLong ?: 0,
        membership = value["membership"]?.asString ?: "join")

    // A reply that mentions you is listed as a mention, as MatrixActivity lists it.
    private fun reply(index: Int, value: JsonObject) = ActivityItem("!room:example.org \$reply$index", "!room:example.org", "\$reply$index",
        "general", false, "Sam", "S", 0, "Sounds good", 1_000L + index,
        if (value["mention"]?.asBoolean == true) ActivityKind.Mention else ActivityKind.ThreadReply, threadRoot = "\$root",
        unread = value["opened"]?.asBoolean != true)
}
