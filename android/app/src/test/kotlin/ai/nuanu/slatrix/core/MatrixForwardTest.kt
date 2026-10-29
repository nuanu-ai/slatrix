package ai.nuanu.slatrix.core

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.matrix.rustcomponents.sdk.*
import uniffi.matrix_sdk_base.EncryptionState
import uniffi.ruma_events.MessageLikeEventType

class MatrixForwardTest {
    private val text = MessageType.Text(TextMessageContent("Ship it", FormattedBody(MessageFormat.Html, "<b>Ship</b> it")))

    // capability: message.forward
    @Test fun aCopyGoesToAJoinedConversationWithoutPingingAnyone() = runTest {
        val destination = ForwardRoom("!general:example.org")
        val forward = MatrixForward(ForwardClient(ForwardRoom("!design:example.org"), destination))

        assertNull(forward.forward(text, "!design:example.org", "!general:example.org"))
        val sent = destination.timeline.sent.single()
        assertEquals(text, sent.type)
        assertEquals(Mentions(emptyList(), false), sent.mentions)
    }

    @Test fun anEncryptedMessageGoesOnlyToAnEncryptedConversation() = runTest {
        val source = ForwardRoom("!design:example.org", EncryptionState.ENCRYPTED)
        for (state in listOf(EncryptionState.NOT_ENCRYPTED, EncryptionState.UNKNOWN)) {
            val destination = ForwardRoom("!general:example.org", state)
            assertEquals("Choose an encrypted conversation for a message from an encrypted one.",
                MatrixForward(ForwardClient(source, destination)).forward(text, source.id(), destination.id()))
            assertEquals(emptyList<ForwardContent>(), destination.timeline.sent)
        }
        val encrypted = ForwardRoom("!secret:example.org", EncryptionState.ENCRYPTED)
        assertNull(MatrixForward(ForwardClient(source, encrypted)).forward(text, source.id(), encrypted.id()))
    }

    @Test fun aConversationYouCantPostInOrHaveLeftIsRefused() = runTest {
        val source = ForwardRoom("!design:example.org")
        val readOnly = ForwardRoom("!announcements:example.org", canPost = false)
        assertEquals("You can’t post in that conversation. Choose another.",
            MatrixForward(ForwardClient(source, readOnly)).forward(text, source.id(), readOnly.id()))
        val left = ForwardRoom("!old:example.org", membership = Membership.LEFT)
        assertEquals("Choose a conversation you’ve joined.",
            MatrixForward(ForwardClient(source, left)).forward(text, source.id(), left.id()))
        assertEquals(emptyList<ForwardContent>(), readOnly.timeline.sent + left.timeline.sent)
    }
}

private class ForwardClient(vararg rooms: ForwardRoom) : Client(NoHandle) {
    private val rooms = rooms.associateBy { it.id() }
    override fun getRoom(roomId: String): Room? = rooms[roomId]
}

private class ForwardRoom(private val roomId: String, private val encryption: EncryptionState = EncryptionState.NOT_ENCRYPTED,
    private val canPost: Boolean = true, private val membership: Membership = Membership.JOINED) : Room(NoHandle) {
    val timeline = ForwardTimeline()
    override fun id(): String = roomId
    override fun membership(): Membership = membership
    override suspend fun latestEncryptionState(): EncryptionState = encryption
    override suspend fun getPowerLevels(): RoomPowerLevels = object : RoomPowerLevels(NoHandle) {
        override fun canOwnUserSendMessage(message: MessageLikeEventType): Boolean = canPost && message is MessageLikeEventType.RoomMessage
    }
    override suspend fun timeline(): Timeline = timeline
}

private class ForwardTimeline : Timeline(NoHandle) {
    val sent = mutableListOf<ForwardContent>()
    override fun createMessageContent(msgType: MessageType): RoomMessageEventContentWithoutRelation = ForwardContent(msgType)
    override suspend fun send(msg: RoomMessageEventContentWithoutRelation): SendHandle {
        sent += msg as ForwardContent
        return object : SendHandle(NoHandle) {}
    }
}

private class ForwardContent(val type: MessageType) : RoomMessageEventContentWithoutRelation(NoHandle) {
    var mentions: Mentions? = null
    override fun withMentions(mentions: Mentions): RoomMessageEventContentWithoutRelation = also { this.mentions = mentions }
}
