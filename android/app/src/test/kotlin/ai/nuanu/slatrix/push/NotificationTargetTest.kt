package ai.nuanu.slatrix.push

import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class NotificationTargetTest {
    // capability: notifications.open
    @Test fun aNotificationWaitsForItsOwnAccountsRealRoom() {
        val team = RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.None, "T", 0)
        val other = team.copy(id = "!other:example.org", name = "Other")
        val target = NotificationTarget("@alex:example.org", team.id)

        assertNull(target.roomFor("@alex:example.org", emptyList()))
        assertNull(target.roomFor("@sam:example.org", listOf(team)))
        assertNull(target.roomFor("@alex:example.org", listOf(other)))
        assertSame(team, target.roomFor("@alex:example.org", listOf(other, team)))
    }
}
