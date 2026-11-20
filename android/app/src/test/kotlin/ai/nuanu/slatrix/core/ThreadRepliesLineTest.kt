package ai.nuanu.slatrix.core

import com.google.gson.JsonElement
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class ThreadRepliesLineTest {
    private val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/thread-replies-line.json").readText()).asJsonObject

    // capability: thread.open
    @Test fun `the replies line under a thread's root says what every shared case says`() {
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            for ((index, element) in case["steps"].asJsonArray.withIndex()) {
                val step = element.asJsonObject
                val replies = step["replies"].asJsonArray.mapIndexed { reply, state ->
                    val deleted = state.asString == "deleted"
                    ConversationMessage("r$reply", "\$r$reply", "@alice:example.org", "Alice", if (deleted) "" else "Yes", null,
                        1_700_000_000_000L, if (deleted) MessageKind.Deleted else MessageKind.Text,
                        if (deleted) MessageSendState.Sent else MessageSendState.valueOf(state.asString.replaceFirstChar(Char::uppercase)),
                        false, "A", 0)
                }
                assertEquals("${case["name"].asString}, step ${index + 1}", step["line"].orNull(),
                    ThreadRepliesLine.count(step["loadedToRoot"].asBoolean, replies, step["rootSummary"].orNull(), step["openedWith"].orNull()))
            }
        }
    }

    private fun JsonElement?.orNull(): Int? = this?.takeUnless { it.isJsonNull }?.asInt
}
