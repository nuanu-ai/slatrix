package ai.nuanu.slatrix.core

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MatrixLinksTest {
    private val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/matrix-links.json").readText()).asJsonObject

    // capability: message.matrix-links
    @Test fun `matrix links parse into the target every shared case names`() {
        for (item in spec["open"].asJsonArray) {
            val case = item.asJsonObject
            val target = case["target"].asJsonObject
            val id = target["id"].asString
            val event = target["event"]?.asString
            val expected = MatrixLink(when (target["kind"].asString) {
                "user" -> MatrixLink.Target.User(id)
                "room" -> MatrixLink.Target.Room(id, event)
                else -> MatrixLink.Target.Alias(id, event)
            }, target["via"]?.asJsonArray?.map { it.asString }.orEmpty())
            assertTrue(case.name(), MatrixLinks.isMatrix(case.link()))
            assertEquals(case.name(), expected, MatrixLinks.parse(case.link()))
        }
    }

    @Test fun `other hosts are not matrix links and malformed ones are refused`() {
        for (item in spec["ignore"].asJsonArray) assertFalse(item.asJsonObject.name(), MatrixLinks.isMatrix(item.asJsonObject.link()))
        for (item in spec["reject"].asJsonArray) {
            val case = item.asJsonObject
            assertTrue(case.name(), MatrixLinks.isMatrix(case.link()))
            assertNull(case.name(), MatrixLinks.parse(case.link()))
        }
        assertNull("An oversized link", MatrixLinks.parse("matrix:u/" + "a".repeat(9_000) + ":example.org"))
    }

    @Test fun `percent sequences in an id are decoded once`() {
        assertEquals(MatrixLink(MatrixLink.Target.User("@ali%0Ace:example.org")), MatrixLinks.parse("https://matrix.to/#/@ali%250Ace:example.org"))
        assertEquals("Emoji keep their whole code point", MatrixLink(MatrixLink.Target.Alias("#😀:example.org")),
            MatrixLinks.parse("matrix:r/😀:example.org"))
        assertNull("Bytes that aren't UTF-8 are refused, not replaced", MatrixLinks.parse("https://matrix.to/#/%23de%FFsign:example.org"))
    }

    private fun JsonObject.name() = this["name"].asString
    private fun JsonObject.link() = this["link"].asString
}
