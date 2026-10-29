package ai.nuanu.slatrix.core

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class PinOrderTest {
    private val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/pinned-messages.json").readText()).asJsonObject

    // capability: conversation.pins
    @Test fun `pins show in every shared case's order`() {
        for (item in spec["order"].asJsonArray) {
            val case = item.asJsonObject
            assertEquals(case["name"].asString, strings(case, "shown"), PinOrder.arrange(strings(case, "pinned"), strings(case, "events")) { it })
        }
    }

    @Test fun `a room past the SDK's limit says how many of its pins show, as every shared case says`() {
        for (item in spec["limit"].asJsonArray) {
            val case = item.asJsonObject
            assertEquals(case["name"].asString, case["note"].takeUnless { it.isJsonNull }?.asString, PinOrder.note(case["total"].asInt))
        }
    }

    private fun strings(case: JsonObject, key: String) = case[key].asJsonArray.map { it.asString }
}
