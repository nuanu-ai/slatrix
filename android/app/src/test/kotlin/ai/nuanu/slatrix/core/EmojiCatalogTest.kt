package ai.nuanu.slatrix.core

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EmojiCatalogTest {
    private val root = File(System.getProperty("slatrix.root"))
    private val spec = JsonParser.parseString(File(root, "spec/emoji.json").readText()).asJsonObject
    private val catalog = EmojiCatalog.parse(File(root, "Sources/Slatrix/Core/EmojiData.swift").readText())

    private fun cases(name: String) = spec[name].asJsonArray.map(com.google.gson.JsonElement::getAsJsonObject)
    private fun JsonObject.strings(name: String) = this[name].asJsonArray.map { it.asString }

    // capability: message.react.picker
    @Test fun `search matches every shared case`() {
        for (case in cases("search")) {
            val results = catalog.search(case["query"].asString).map { it.value }
            val name = case["name"].asString
            assertEquals(name, case["first"].takeUnless { it.isJsonNull }?.asString, results.firstOrNull())
            val positions = case["order"]?.asJsonArray?.map { expected -> results.indexOf(expected.asString) }.orEmpty()
            assertTrue(name, positions.none { it < 0 } && positions == positions.sorted())
        }
    }

    @Test fun `shortcodes match every shared case`() {
        for (case in cases("shortcode")) {
            assertEquals(case["name"].asString, case["shortcode"].asString, catalog.shortcode(case["value"].asString))
        }
    }

    // capability: message.react.quick
    @Test fun `quick reactions match every shared case`() {
        for (case in cases("quick")) {
            assertEquals(case["name"].asString, case.strings("quick"), EmojiRecents.quick(case.strings("recent"), case["count"].asInt))
        }
        for (case in cases("adding")) {
            assertEquals(case["name"].asString, case.strings("after"), EmojiRecents.adding(case["emoji"].asString, case.strings("recent")))
        }
    }

    @Test fun `every category holds emoji and every emoji has a shortcode and a name`() {
        assertEquals(EmojiCategory.entries.toSet(), catalog.all.map { it.category }.toSet())
        assertTrue(catalog.all.all { it.value.isNotEmpty() && it.shortcodes.isNotEmpty() && it.name.isNotEmpty() })
    }
}
