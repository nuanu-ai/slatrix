package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.Membership
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.Room

class InvitationsTest {
    @Test fun roomsArePlacedAsInEverySharedCase() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/invitations.json").readText()).asJsonObject
        val memberships = mapOf("invited" to Membership.INVITED, "joined" to Membership.JOINED, "left" to Membership.LEFT,
            "banned" to Membership.BANNED)
        val placements = mapOf("conversation" to RoomPlacement.Conversation, "workspace" to RoomPlacement.Workspace,
            "ignored" to RoomPlacement.Ignored)
        for (item in spec["placement"].asJsonArray) {
            val case = item.asJsonObject
            assertEquals(case["name"].asString, placements.getValue(case["expected"].asString),
                RoomPlacement.of(case["space"].asBoolean, memberships.getValue(case["membership"].asString)))
        }
    }

    // capability: home.invitations
    @Test fun acceptingJoinsAndDecliningLeaves() = runTest {
        val accepted = InvitedRoom("!design:example.org")
        val declined = InvitedRoom("!harbor:example.org")
        val client = InvitationsClient(accepted, declined)

        assertTrue(Invitations.respond(client, accepted.id(), accept = true))
        assertTrue(Invitations.respond(client, declined.id(), accept = false))
        assertEquals(listOf("join"), accepted.writes)
        assertEquals(listOf("leave"), declined.writes)
    }

    @Test fun anInvitationNoLongerPendingIsLeftAlone() = runTest {
        val joined = InvitedRoom("!design:example.org", Membership.JOINED)
        assertFalse(Invitations.respond(InvitationsClient(joined), joined.id(), accept = true))
        assertEquals(emptyList<String>(), joined.writes)
    }

    @Test fun aRefusedJoinSaysSo() = runTest {
        val failing = InvitedRoom("!ops:example.org").apply { fails = true }
        assertFalse(Invitations.respond(InvitationsClient(failing), failing.id(), accept = true))
    }
}

private class InvitationsClient(private vararg val rooms: Room) : Client(NoHandle) {
    override fun getRoom(roomId: String): Room? = rooms.firstOrNull { it.id() == roomId }
}

private class InvitedRoom(private val id: String, private var membership: Membership = Membership.INVITED) : Room(NoHandle) {
    val writes = mutableListOf<String>()
    var fails = false
    override fun id(): String = id
    override fun membership(): Membership = membership
    override suspend fun join() {
        if (fails) throw IllegalStateException("Forbidden")
        writes += "join"
        membership = Membership.JOINED
    }
    override suspend fun leave() {
        writes += "leave"
        membership = Membership.LEFT
    }
}
