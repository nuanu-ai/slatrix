package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class WorkspaceMembershipTest {
    @Test fun workspaceScopeMatchesEverySharedCase() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/workspace-membership.json").readText()).asJsonObject
        for (item in spec["cases"].asJsonArray) {
            val case = item.asJsonObject
            assertEquals(case["name"].asString, case["included"].asBoolean, WorkspaceMembership.includes(
                direct = case["direct"].asBoolean,
                spaceIds = case["spaceIds"].asJsonArray.map { it.asString }.toSet(),
                spaceId = case["spaceId"].takeUnless { it.isJsonNull }?.asString,
            ))
        }
    }
}
