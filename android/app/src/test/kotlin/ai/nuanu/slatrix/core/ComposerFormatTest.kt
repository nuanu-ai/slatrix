package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class ComposerFormatTest {
    @Test fun `message matches every shared composer case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/composer.json").readText()).asJsonObject
        for (item in spec["send"].asJsonArray) {
            val case = item.asJsonObject
            val expected = ComposerMessage(
                body = case["body"].asString,
                html = case["html"].takeUnless { it.isJsonNull }?.asString,
                mentions = case["mentions"].asJsonArray.map { it.asString },
                mentionsRoom = case["mentionsRoom"].asBoolean,
            )
            assertEquals(case["name"].asString, expected, ComposerFormat.message(case["draft"].asString))
        }
    }

    @Test fun `plain input preserves markup characters and line breaks without formatting`() {
        val draft = ComposerFormat.draft("<strong>**six** & \"seven\"</strong>\n> quote")
        assertEquals(
            ComposerMessage("<strong>**six** & \"seven\"</strong>\n> quote", null, emptyList(), false),
            ComposerFormat.message(draft),
        )
    }

    @Test fun `plain input keeps leading and repeated spaces on each line`() {
        val draft = ComposerFormat.draft("  keep  spaces\n next")
        assertEquals(
            ComposerMessage("  keep  spaces\n next", null, emptyList(), false),
            ComposerFormat.message(draft),
        )
    }
}
