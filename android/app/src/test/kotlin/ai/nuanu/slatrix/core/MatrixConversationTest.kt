package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.*

class MatrixConversationTest {
    @Test fun cachedMessagesAppearWhileOlderHistoryIsStillLoading() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        runCurrent()

        val message = conversation.state.value.messages.single()
        assertEquals("stable-1", message.id)
        assertEquals("\$one", message.eventId)
        assertEquals("Hello", message.body)
        assertEquals("Mira Chen", message.senderName)
        assertEquals("MC", message.initials)
        conversation.close()
    }

    @Test fun sendPreservesComposerFieldsAndAcceptsOnlyTheSdkQueueResult() = runTest {
        val timeline = ConversationTimeline(emptyList())
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        runCurrent()
        val message = ComposerMessage(
            body = "Hello Mira", html = "Hello <strong>Mira</strong>",
            mentions = listOf("@mira:example.org"), mentionsRoom = true,
        )
        val sending = async { conversation.send(message) }
        runCurrent()
        assertTrue(conversation.state.value.sending)
        val content = timeline.submissions.receive()
        val text = (content.type as MessageType.Text).content
        assertEquals("Hello Mira", text.body)
        assertEquals("Hello <strong>Mira</strong>", text.formatted?.body)
        assertEquals(listOf("@mira:example.org"), content.mentions?.userIds)
        assertEquals(true, content.mentions?.room)
        assertEquals(emptyList<ConversationMessage>(), conversation.state.value.messages)
        timeline.sendResults.send(Result.success(object : SendHandle(NoHandle) {}))
        assertTrue(sending.await())
        assertEquals(emptyList<ConversationMessage>(), conversation.state.value.messages)

        val rejected = async { conversation.send(message) }
        timeline.submissions.receive()
        timeline.sendResults.send(Result.failure(IllegalStateException("Store unavailable")))
        assertFalse(rejected.await())
        assertNotNull(conversation.state.value.sendError)
        conversation.close()
    }
}

private class ConversationRoom(private val value: Timeline) : Room(NoHandle) {
    override suspend fun timeline(): Timeline = value
}

private class ConversationTimeline(private val cached: List<TimelineItem>) : Timeline(NoHandle) {
    private var listener: TimelineListener? = null
    val page = CompletableDeferred<Boolean>()
    val submissions = Channel<ConversationContent>(Channel.UNLIMITED)
    val sendResults = Channel<Result<SendHandle>>(Channel.UNLIMITED)
    override suspend fun addListener(listener: TimelineListener): TaskHandle {
        this.listener = listener
        listener.onUpdate(listOf(TimelineDiff.Reset(cached)))
        return object : TaskHandle(NoHandle) { override fun cancel() = Unit }
    }
    override suspend fun paginateBackwards(numEvents: UShort): Boolean = page.await()
    override fun createMessageContent(msgType: MessageType): RoomMessageEventContentWithoutRelation = ConversationContent(msgType)
    override suspend fun send(msg: RoomMessageEventContentWithoutRelation): SendHandle {
        submissions.send(msg as ConversationContent)
        return sendResults.receive().getOrThrow()
    }
}

private class ConversationContent(val type: MessageType) : RoomMessageEventContentWithoutRelation(NoHandle) {
    var mentions: Mentions? = null
    override fun withMentions(mentions: Mentions): RoomMessageEventContentWithoutRelation {
        this.mentions = mentions
        return this
    }
}

private fun conversationItem(stableId: String, eventId: String, body: String): TimelineItem {
    val event = EventTimelineItem(
        isRemote = true, eventOrTransactionId = EventOrTransactionId.EventId(eventId),
        sender = "@mira:example.org",
        senderProfile = ProfileDetails.Ready("Mira Chen", false, null, null, null),
        forwarder = null, forwarderProfile = null, isOwn = false, isEditable = false,
        content = TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent(body, null)), body, false, null)),
            null, null, null,
        )),
        reactions = emptyList(), eventTypeRaw = "m.room.message", timestamp = 1_700_000_000_000u,
        localSendState = null, editSendState = null, redactionSendState = null, localCreatedAt = null,
        readReceipts = emptyMap(), origin = null, canBeRepliedTo = true,
        lazyProvider = object : LazyTimelineItemProvider(NoHandle) {},
    )
    return object : TimelineItem(NoHandle) {
        override fun uniqueId(): TimelineUniqueId = TimelineUniqueId(stableId)
        override fun asEvent(): EventTimelineItem = event
    }
}
