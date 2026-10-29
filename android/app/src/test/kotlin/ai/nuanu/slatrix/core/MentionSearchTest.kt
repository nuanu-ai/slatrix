package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class MentionSearchTest {
    // capability: composer.mentions
    @Test fun `suggestions match every shared case`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/mention-search.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            val members = case["members"].asJsonArray.map { it.asJsonObject }.map {
                MentionPerson(it["id"].asString, it["name"].asString, it["membership"]?.asString ?: "join")
            }
            val found = MentionSearch.suggestions(case["before"].asString, members,
                case["recentSenders"]?.asJsonArray?.map { it.asString }.orEmpty(), case["offersRoom"].asBoolean)
            val name = case["name"].asString
            assertEquals(name, case["suggestions"].takeUnless { it.isJsonNull }?.asJsonArray?.map { it.asString },
                found?.candidates?.map { (it as? MentionCandidate.Member)?.person?.id ?: "@room" })
            case["range"]?.asJsonArray?.let { range ->
                assertEquals(name, range[0].asInt to range[1].asInt, found?.let { it.start to it.end - it.start })
            }
        }
    }
}
