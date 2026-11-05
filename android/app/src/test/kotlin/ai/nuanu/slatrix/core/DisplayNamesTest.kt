package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class DisplayNamesTest {
    // capability: people.names
    @Test fun `a person's name and mention match every shared case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/display-names.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            fun text(key: String) = case[key].takeUnless { it.isJsonNull }?.asString
            val name = DisplayNames.name(case["userId"].asString, text("memberName"), text("globalName"), case["ambiguous"].asBoolean)
            assertEquals(case["case"].asString, case["name"].asString, name)
            assertEquals(case["case"].asString, case["mention"].asString, DisplayNames.mention(name))
        }
        for (item in spec["text"].asJsonArray) {
            val case = item.asJsonObject
            val members = case["members"].asJsonObject.entrySet().associate { it.key to it.value.asString }
            assertEquals(case["case"].asString, case["result"].asString, DisplayNames.mentions(case["text"].asString, members))
        }
        for (item in spec["pills"].asJsonArray) {
            val case = item.asJsonObject
            val members = case["members"].asJsonObject.entrySet().associate { it.key to it.value.asString }
            val runs = MessageBodyRenderer.render(case["body"].asString, case["html"].takeUnless { it.isJsonNull }?.asString)
            assertEquals(case["case"].asString, case["result"].asString, MessageBodyRenderer.named(runs, members).joinToString("") { it.text })
        }
    }
}
