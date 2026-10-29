package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class MessageGroupingTest {
    @Test fun `grouping matches every shared case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/message-grouping.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            val messages = case["messages"].asJsonArray.mapIndexed { index, value ->
                val message = value.asJsonObject
                ConversationMessage("m$index", "\$m$index", message["sender"].asString, message["sender"].asString, "", null,
                    1_700_000_000_000L + message["second"].asLong * 1_000, MessageKind.Text, MessageSendState.Sent, false, "", 0)
            }
            val grouped = messages.indices.map { it > 0 && groupsUnder(messages[it - 1], messages[it]) }
            assertEquals(case["name"].asString, case["grouped"].asJsonArray.map { it.asBoolean }, grouped)
        }
    }
}
