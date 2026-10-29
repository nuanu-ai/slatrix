package ai.nuanu.slatrix.core

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

// capability: home.workspace-switcher
class WorkspaceRailTest {
    private val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/workspace-rail.json").readText()).asJsonObject

    @Test fun theSwitcherOffersEverySharedCasesWorkspaces() {
        for (item in spec["entries"].asJsonArray) {
            val case = item.asJsonObject
            val entries = WorkspaceRail.entries(spaces(case["workspaces"].asJsonArray), rooms(case["rooms"].asJsonArray))
            assertEquals(case["name"].asString, case["expected"].asJsonArray.map { it.string() }, entries.map { it?.id })
        }
    }

    @Test fun everySharedCasesWorkspaceOpens() {
        for (item in spec["choose"].asJsonArray) {
            val case = item.asJsonObject
            val base = if (case["busy"]?.asBoolean == true) spec["busyRooms"].asJsonArray else case["rooms"].asJsonArray
            val rooms = rooms(base) + rooms(case["extraRooms"]?.asJsonArray ?: JsonArray())
            val chosen = WorkspaceRail.choose(case["remembered"].string(), rooms.firstOrNull { it.id == case["showing"]?.string() },
                spaces(case["workspaces"].asJsonArray), rooms)
            assertEquals(case["name"].asString, case["expected"].string(), chosen)
        }
    }

    private fun spaces(ids: JsonArray) = ids.map { id ->
        val known = spec["workspaces"].asJsonArray.map { it.asJsonObject }.first { it["id"].asString == id.asString }
        SpaceSummary(known["id"].asString, known["name"].asString, isTopLevel = known["topLevel"]?.asBoolean ?: true)
    }

    // Android's room list holds joined rooms only, so an invitation never reaches the rail.
    private fun rooms(items: JsonArray) = items.map(JsonElement::getAsJsonObject).filter { it.text("membership", "join") == "join" }.map {
        RoomSummary(it["id"].asString, it["id"].asString, it["direct"]?.asBoolean ?: false, "", UnreadBadge.None, "", 0,
            spaceIds = it["spaces"]?.asJsonArray?.map { space -> space.asString }?.toSet() ?: emptySet())
    }

    private fun JsonObject.text(key: String, fallback: String) = get(key)?.asString ?: fallback

    private fun JsonElement?.string(): String? = this?.takeUnless { it.isJsonNull }?.asString
}
