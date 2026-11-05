package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class ReadStateTest {
    private val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/read-state.json").readText()).asJsonObject

    // capability: conversation.read
    @Test fun `the newest message counts as seen where every shared case says`() {
        for (item in spec["seen"].asJsonArray) {
            val case = item.asJsonObject
            val (top, bottom) = case["message"].asJsonArray.map { it.asFloat }
            val (screenTop, screenBottom) = case["screen"].asJsonArray.map { it.asFloat }
            assertEquals(case["name"].asString, case["seen"].asBoolean, ReadState.seen(top, bottom, screenTop, screenBottom))
        }
    }
}
