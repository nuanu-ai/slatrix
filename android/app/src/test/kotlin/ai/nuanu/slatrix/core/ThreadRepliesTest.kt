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
            // A reply the server hasn't confirmed has no event ID yet.
            val replies = case["replies"].asJsonArray.mapIndexed { index, confirmed -> "\$r$index".takeIf { confirmed.asBoolean } }
            val divider = case["divider"].takeUnless { it.isJsonNull }?.asString
            assertEquals(case["name"].asString, divider, ThreadReplies.divider(case["loaded"].asBoolean, replies))
        }
    }
}
