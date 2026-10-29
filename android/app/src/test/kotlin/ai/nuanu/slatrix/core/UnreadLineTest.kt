package ai.nuanu.slatrix.core

import com.google.gson.JsonElement
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class UnreadLineTest {
    private val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/unread-line.json").readText()).asJsonObject

    // capability: conversation.unread-line
    @Test fun `the New line goes where every shared case puts it`() {
        for (item in spec["line"].asJsonArray) {
            val case = item.asJsonObject
            val marks = case["items"].asJsonArray.map {
                when (val value = it.asString) {
                    "marker" -> UnreadLine.Mark(readMarker = true)
                    "hidden" -> UnreadLine.Mark()
                    else -> UnreadLine.Mark(shown = value)
                }
            }
            assertEquals(case["name"].asString, case["line"].orNull(), UnreadLine.first(marks))
        }
    }

    @Test fun `an unread conversation opens where every shared case says`() {
        for (item in spec["resume"].asJsonArray) {
            val case = item.asJsonObject
            val room = case["room"].asJsonObject
            val unread = RoomUnread(
                markedUnread = room["markedUnread"]?.asBoolean ?: false,
                messages = room["messages"]?.asLong ?: 0,
                notifications = room["notifications"]?.asLong ?: 0,
                membership = room["membership"]?.asString ?: "join",
            )
            assertEquals(case["name"].asString, case["anchor"].orNull(), UnreadLine.resumeAt(unread, room["fullyRead"].orNull()))
        }
    }

    private fun JsonElement?.orNull(): String? = this?.takeUnless { it.isJsonNull }?.asString
}
