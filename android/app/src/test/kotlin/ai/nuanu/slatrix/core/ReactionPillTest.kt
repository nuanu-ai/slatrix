package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class ReactionPillTest {
    // capability: message.reactions.show
    @Test fun `a reaction's pill matches every shared case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/reactions.json").readText()).asJsonObject
        for (item in spec["pill"].asJsonArray) {
            val case = item.asJsonObject
            val me = case["me"].asString
            val senders = case["senders"].asJsonArray.map { it.asString }
            val reaction = MessageReaction("👍", case["count"].asInt, me in senders, senders)
            assertEquals(case["name"].asString, case["faces"]?.asJsonArray?.map { it.asString }, reaction.faces(me))
        }
    }
}
