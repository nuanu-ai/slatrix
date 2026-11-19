package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class ThreadRepliesTest {
    @Test fun `the line under a thread's root matches every shared case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/thread-replies.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            val replies = case["replies"].asJsonArray.mapIndexed { index, state ->
                val deleted = state.asString == "deleted"
                ConversationMessage("r$index", "\$r$index", "@alice:example.org", "Alice", if (deleted) "" else "Yes", null,
                    1_700_000_000_000L, if (deleted) MessageKind.Deleted else MessageKind.Text,
                    if (deleted) MessageSendState.Sent else MessageSendState.valueOf(state.asString.replaceFirstChar(Char::uppercase)),
                    false, "A", 0)
            }
            val divider = case["divider"].takeUnless { it.isJsonNull }?.asString
            assertEquals(case["name"].asString, divider, ThreadReplies.divider(case["count"].asInt, replies))
        }
    }
}
