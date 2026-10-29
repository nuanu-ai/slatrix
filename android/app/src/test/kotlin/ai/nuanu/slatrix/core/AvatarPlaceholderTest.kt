package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class AvatarPlaceholderTest {
    // capability: people.avatars
    @Test fun `initials and colors match every shared avatar case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/avatar.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            val name = case["value"].asString
            assertEquals(name, case["initials"].asString, AvatarPlaceholder.initials(name))
            assertEquals(name, case["color"].asInt, AvatarPlaceholder.colorIndex(name))
        }
    }
}
