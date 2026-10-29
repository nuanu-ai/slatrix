package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
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
}

private class ConversationRoom(private val value: Timeline) : Room(NoHandle) {
    override suspend fun timeline(): Timeline = value
}

private class ConversationTimeline(private val cached: List<TimelineItem>) : Timeline(NoHandle) {
    private var listener: TimelineListener? = null
    val page = CompletableDeferred<Boolean>()
    override suspend fun addListener(listener: TimelineListener): TaskHandle {
        this.listener = listener
        listener.onUpdate(listOf(TimelineDiff.Reset(cached)))
        return object : TaskHandle(NoHandle) { override fun cancel() = Unit }
    }
    override suspend fun paginateBackwards(numEvents: UShort): Boolean = page.await()
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
