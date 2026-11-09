package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class ConnectionStateTest {
    @Test fun sharedConnectionStates() {
        val cases = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/connection-state.json").readText()).asJsonObject["cases"].asJsonArray
        for (value in cases) {
            val row = value.asJsonObject
            val state = ConnectionState.resolve(row["network"].takeUnless { it.isJsonNull }?.asBoolean,
                row["foreground"].asBoolean, row["running"].asBoolean, row["responded"].asBoolean,
                row["interrupted"].asBoolean, row["previouslyConnected"].asBoolean)
            assertEquals(row["name"].asString, row["state"].asString, state.name.lowercase())
            assertEquals(row["name"].asString, row["label"].asString, state.label)
        }
    }
}
