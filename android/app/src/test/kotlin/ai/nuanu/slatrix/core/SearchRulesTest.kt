package ai.nuanu.slatrix.core

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Test

/** Message search and conversation ranking, from the shared cases in `spec/`. */
class SearchRulesTest {
    private fun spec(name: String) = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/$name").readText()).asJsonObject

    // capability: search.rooms
    // capability: search.people
    @Test fun conversationsRankAsInEverySharedCase() {
        for (item in spec("conversation-search.json")["cases"].asJsonArray) {
            val case = item.asJsonObject
            // Android's room list holds joined rooms only, and keeps spaces apart from them.
            val rooms = case["rooms"].asJsonArray.map { it.asJsonObject }
                .filter { (it["membership"]?.asString ?: "join") == "join" && it["space"]?.asBoolean != true }
                .mapIndexed { index, room -> RoomSummary("!$index:example.org", room["name"].asString, room["direct"]?.asBoolean ?: false, "", UnreadBadge.None, "", 0) }
            val visited = case["visited"]?.asJsonArray?.map { name -> rooms.first { it.name == name.asString }.id }.orEmpty()
            assertEquals(case["name"].asString, case["expected"].asJsonArray.map { it.asString },
                ConversationSearch.results(rooms, case["query"].asString, visited).map { it.name })
        }
    }

    // capability: search.messages
    @Test fun slacksInAndFromReadAsInEverySharedCase() {
        val spec = spec("search-query.json")
        val rooms = spec["rooms"].asJsonArray.map { it.asJsonObject }
            .map { RoomSummary(it["id"].asString, it["name"].asString, false, "", UnreadBadge.None, "", 0) }
        for (item in spec["parse"].asJsonArray) {
            val case = item.asJsonObject
            assertEquals(case["name"].asString, MessageSearchQuery(case["text"].asString, roomId = case.text("roomID"), senderId = case.text("senderID")),
                MessageSearchQuery.parse(case["input"].asString, rooms, spec["me"].asString))
        }
    }

    // capability: search.messages
    @Test fun theIndexQueryIsAsInEverySharedCase() {
        for (item in spec("search-query.json")["query"].asJsonArray) {
            val case = item.asJsonObject
            val query = MessageSearchQuery(case["text"].asString, mode(case), date = case.text("date")?.let { dates.getValue(it) },
                roomId = case.text("roomID"), senderId = case.text("senderID"))
            val now = case.text("now")?.let(Instant::parse) ?: Instant.now()
            assertEquals(case["name"].asString, case.text("query"), query.sdkQuery(now, ZoneOffset.UTC))
        }
    }

    @Test fun highlightedWordsAreAsInEverySharedCase() {
        for (item in spec("search-query.json")["highlights"].asJsonArray) {
            val case = item.asJsonObject
            val body = case["body"].asString
            assertEquals(case["name"].asString, case["words"].asJsonArray.map { it.asString },
                MessageSearchQuery(case["text"].asString, mode(case)).highlights(body).map { body.substring(it) })
        }
    }

    private val dates = mapOf("today" to SearchDate.Today, "week" to SearchDate.Week, "month" to SearchDate.Month, "year" to SearchDate.Year)

    private fun mode(case: JsonObject) = when (case["mode"].asString) {
        "query" -> MessageSearchQuery.Mode.Query
        "phrase" -> MessageSearchQuery.Mode.Phrase
        else -> error("Unknown mode")
    }

    private fun JsonObject.text(key: String): String? = get(key)?.takeUnless(JsonElement::isJsonNull)?.asString
}
