package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

class PresenceTest {
    @Test fun `a person's dot matches every shared case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/presence.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            fun state(key: String) = case[key].takeUnless { it.isJsonNull }?.asString
            val dot = state("dot")?.let { name -> Presence.entries.single { it.name.equals(name, ignoreCase = true) } }
            assertEquals(case["name"].asString, dot, PresencePolicy.dot(state("own"), state("theirs")))
        }
    }

    @Test fun `a server that reports you offline while you're connected gives nobody a dot`() = runTest {
        val states = mapOf("@me" to "offline", "@anna" to "online")
        assertEquals(emptyMap<String, Presence>(), PresencePolicy.dots("@me", listOf("@anna")) { states[it] })
    }
}
