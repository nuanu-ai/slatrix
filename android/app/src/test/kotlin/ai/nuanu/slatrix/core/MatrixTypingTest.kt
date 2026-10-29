package ai.nuanu.slatrix.core

import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.TypingNotificationsListener

class MatrixTypingTest {
    // capability: composer.typing
    @Test fun typingTellsTheRoomUntilItPausesForThreeSecondsOrSendsOrClears() = runTest {
        val room = TypingRoom()
        val typing = MatrixTyping(backgroundScope, TypingClient(room), room.id())

        typing.changed("H")
        runCurrent()
        advanceTimeBy(2_000)
        typing.changed("He")
        runCurrent()
        assertEquals(listOf(true, true), room.notices)
        advanceTimeBy(3_001)
        assertEquals("Three seconds after the last change it stopped", listOf(true, true, false), room.notices)

        typing.changed("Hel")
        runCurrent()
        typing.stopped()
        runCurrent()
        assertEquals(listOf(true, true, false, true, false), room.notices)
        typing.changed("")
        runCurrent()
        assertEquals("Clearing the field says you stopped", false, room.notices.last())
    }

    @Test fun othersTypingShowByNameButNeverYou() = runTest {
        val room = TypingRoom()
        val others = MatrixTyping(backgroundScope, TypingClient(room), room.id()).others
            .stateIn(backgroundScope, SharingStarted.Eagerly, null)
        val listener = room.listener.first { it != null }!!

        listener.call(listOf("@me:example.org", "@sam:example.org", "@quinn:example.org"))
        assertEquals(listOf("Sam Okafor", "quinn"), others.first { !it.isNullOrEmpty() })
        listener.call(emptyList())
        others.first { it == emptyList<String>() }
    }
}

private class TypingClient(private val room: Room) : Client(NoHandle) {
    override fun getRoom(roomId: String): Room = room
}

private class TypingRoom : Room(NoHandle) {
    val notices = mutableListOf<Boolean>()
    val listener = kotlinx.coroutines.flow.MutableStateFlow<TypingNotificationsListener?>(null)
    override fun id(): String = "!design:example.org"
    override fun ownUserId(): String = "@me:example.org"
    override suspend fun typingNotice(isTyping: Boolean) { notices += isTyping }
    override suspend fun memberDisplayName(userId: String): String? = if (userId == "@sam:example.org") "Sam Okafor" else null
    override fun subscribeToTypingNotifications(listener: TypingNotificationsListener): TaskHandle {
        this.listener.value = listener
        return object : TaskHandle(NoHandle) { override fun cancel() = Unit }
    }
}
