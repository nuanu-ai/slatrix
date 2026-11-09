package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class SeenPolicyTest {
    @Test fun `who has read each of your messages matches every shared case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/seen.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            val messages = case["messages"].asJsonArray.map { it.asJsonObject }.map { message ->
                Triple(message["id"].asString, message["sender"].asString, message["readBy"].asJsonArray.map { it.asString })
            }
            val seen = case["seen"].asJsonObject.entrySet().associate { (id, readers) -> id to readers.asJsonArray.map { it.asString } }
            assertEquals(case["name"].asString, seen, SeenPolicy.readers(messages, case["me"].asString))
        }
    }
}
