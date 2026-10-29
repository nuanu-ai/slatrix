package ai.nuanu.slatrix.core

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class MessageFormatTest {
    // capability: message.rich-text
    @Test fun `a message's text shows as every shared case says`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/message-format.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            val expected = case["runs"].asJsonArray.map { expectedRun(it.asJsonObject) }
            val html = case["html"].takeUnless { it.isJsonNull }?.asString
            assertEquals(case["name"].asString, expected, MessageFormat.render(case["body"].asString, html))
        }
    }

    private fun expectedRun(run: JsonObject) = MessageRun(
        text = run["text"].asString,
        styles = run["style"]?.asJsonArray?.map { TextStyle.valueOf(it.asString.replaceFirstChar(Char::uppercaseChar)) }?.toSet().orEmpty(),
        link = run["link"]?.asString,
        mention = run["mention"]?.asString,
        block = MessageBlock(quote = run["quote"]?.asInt ?: 0, list = run["list"]?.asInt ?: 0, code = run["code"]?.asBoolean ?: false),
        marker = run["marker"]?.asBoolean ?: false,
    )
}
