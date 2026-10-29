package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.*

class MatrixConversationTest {
    @Test fun cachedMessagesAppearWhileOlderHistoryIsStillLoading() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val message = conversation.state.first { it.rows.messages.isNotEmpty() }.rows.messages.single()
        assertEquals("stable-1", message.id)
        assertEquals("\$one", message.eventId)
        assertEquals("Hello", message.body)
        assertEquals("Mira Chen", message.senderName)
        assertEquals("MC", message.initials)
        conversation.close()
    }

    @Test fun aResetOrClearedTimelineLoadsOlderHistoryAgain() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.state.first { it.rows.isNotEmpty() }
        conversation.loadOlder()
        timeline.page.complete(true)
        conversation.state.first { !it.hasMore }

        timeline.emit(listOf(TimelineDiff.Reset(listOf(conversationItem("stable-2", "\$two", "Again")))))
        assertTrue(conversation.state.first { it.rows.messages.firstOrNull()?.id == "stable-2" }.hasMore)
        conversation.loadOlder()
        conversation.state.first { !it.hasMore }
        timeline.emit(listOf(TimelineDiff.Clear))
        assertTrue(conversation.state.first { it.rows.messages.isEmpty() }.hasMore)
        conversation.close()
    }

    @Test fun aFailedReadReceiptStaysQuietAndALaterReadRetries() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.state.first { it.rows.messages.isNotEmpty() }
        timeline.receiptFailure = IllegalStateException("Offline")

        assertFalse(conversation.markRead("\$one"))
        assertNull(conversation.state.value.error)
        timeline.receiptFailure = null
        assertTrue(conversation.markRead("\$one"))
        assertEquals(ReceiptType.READ to "\$one", timeline.receipts.receive())
        conversation.close()
    }

    @Test fun retryLoadsFailedHistoryAgainWithoutLosingMessages() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        timeline.pageFailure = IllegalStateException("Offline")
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.loadOlder()
        conversation.state.first { it.error != null && !it.loadingHistory && it.rows.isNotEmpty() }
        assertTrue(conversation.markRead("\$one"))
        assertNotNull("Reading must not hide the history error", conversation.state.value.error)

        timeline.pageFailure = null
        timeline.page.complete(true)
        assertTrue(conversation.retry())
        val loaded = conversation.state.first { !it.hasMore }
        assertNull(loaded.error)
        assertEquals(listOf("Hello"), loaded.rows.messages.map { it.body })
        conversation.close()
    }

    @Test fun retryLeavesATimelineThatNeverOpenedToBeReopened() = runTest {
        val room = ConversationRoom(ConversationTimeline(emptyList()))
        room.openFailure = IllegalStateException("Store unavailable")
        val conversation = MatrixConversation(backgroundScope, room)
        conversation.state.first { it.error != null }
        assertFalse(conversation.retry())
        conversation.close()
    }

    @Test fun timelineUpdatesAreMappedOffTheCallersThread() = runTest {
        val caller = Thread.currentThread()
        var mappedOn: Thread? = null
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello") { mappedOn = Thread.currentThread() }))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.state.first { it.rows.messages.isNotEmpty() }
        assertNotSame(caller, mappedOn)
        conversation.close()
    }

    @Test fun dayDividersSplitTheTimelineAndASendersRunGroupsWithinFiveMinutes() = runTest {
        val start = 1_700_000_000_000uL
        val minute = 60_000uL
        val timeline = ConversationTimeline(listOf(
            dateDivider("day-1", start),
            conversationItem("a", "\$a", "First", timestamp = start),
            conversationItem("b", "\$b", "Second", timestamp = start + minute),
            conversationItem("c", "\$c", "Third", sender = "@sam:example.org", timestamp = start + 2u * minute),
            conversationItem("d", "\$d", "Fourth", sender = "@sam:example.org", timestamp = start + 7u * minute),
            dateDivider("day-2", start + 8u * minute),
            conversationItem("e", "\$e", "Fifth", sender = "@sam:example.org", timestamp = start + 8u * minute),
        ))
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        val rows = conversation.state.first { it.rows.isNotEmpty() }.rows
        assertEquals(listOf("day", "First", "+Second", "Third", "Fourth", "day", "Fifth"), rows.map {
            when (it) { is DayDivider -> "day"; is ConversationMessage -> if (it.grouped) "+${it.body}" else it.body }
        })
        assertEquals(1_700_000_000_000L, (rows.first() as DayDivider).timestamp)

        timeline.emit(listOf(TimelineDiff.Remove(1u)))
        assertEquals("Removing the run's first message ungroups the next", listOf("day", "Second", "Third"),
            conversation.state.first { it.rows.size == 6 }.rows.take(3).map { (it as? ConversationMessage)?.body ?: "day" })
        conversation.close()
    }

    @Test fun historyStopsAfterFiveBlankPagesUntilAnOlderMessageShows() = runTest {
        val timeline = ConversationTimeline(listOf(conversationItem("stable-1", "\$one", "Hello")))
        timeline.page.complete(false)
        val conversation = MatrixConversation(backgroundScope, ConversationRoom(timeline))
        conversation.state.first { it.rows.isNotEmpty() }
        repeat(6) { conversation.loadOlder(); runCurrent() }
        assertEquals("Pages of hidden events stop after five", 5, timeline.pages)

        timeline.emit(listOf(TimelineDiff.PushFront(conversationItem("stable-0", "\$zero", "Earlier"))))
        conversation.state.first { it.rows.first().id == "stable-0" }
        conversation.loadOlder()
        runCurrent()
        assertEquals(6, timeline.pages)
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
        assertEquals(emptyList<ConversationMessage>(), conversation.state.value.rows.messages)
        timeline.sendResults.send(Result.success(object : SendHandle(NoHandle) {}))
        assertTrue(sending.await())
        assertEquals(emptyList<ConversationMessage>(), conversation.state.value.rows.messages)

        val rejected = async { conversation.send(message) }
        timeline.submissions.receive()
        timeline.sendResults.send(Result.failure(IllegalStateException("Store unavailable")))
        assertFalse(rejected.await())
        assertNotNull(conversation.state.value.sendError)
        conversation.close()
    }

    @Test fun onlyVisibleLatestMessagesAreReadAndClosedTimelinesRejectLateUpdates() = runTest {
        val divider = object : TimelineItem(NoHandle) {
            override fun asEvent(): EventTimelineItem? = null
            override fun asVirtual(): VirtualTimelineItem = VirtualTimelineItem.ReadMarker
        }
        val timeline = ConversationTimeline(listOf(
            divider,
            conversationItem("stable-old", "\$old", "Earlier"),
            conversationItem("stable-new", "transaction", "Queued", local = true),
        ))
        val room = ConversationRoom(timeline)
        val conversation = MatrixConversation(backgroundScope, room)
        timeline.pageStarted.await()
        assertEquals(MessageSendState.Sending, conversation.state.first { it.rows.messages.size == 2 }.rows.messages.last().sendState)

        timeline.emit(listOf(TimelineDiff.Set(2u, conversationItem("stable-new", "\$new", "Delivered"))))
        conversation.state.first { it.rows.messages.last().body == "Delivered" }
        assertEquals("stable-new", conversation.state.value.rows.messages.last().id)
        assertEquals("\$new", conversation.state.value.rows.messages.last().eventId)
        assertEquals(MessageSendState.Sent, conversation.state.value.rows.messages.last().sendState)
        val encrypted = TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.UnableToDecrypt(EncryptedMessage.Unknown), null, null, null,
        ))
        timeline.emit(listOf(TimelineDiff.Set(2u, conversationItem("stable-new", "\$new", "", content = encrypted))))
        conversation.state.first { it.rows.messages.last().kind == MessageKind.Encrypted }
        assertEquals(MessageKind.Encrypted, conversation.state.value.rows.messages.last().kind)
        assertEquals("Waiting for this message", conversation.state.value.rows.messages.last().body)

        assertFalse(conversation.markRead("\$old"))
        assertTrue(timeline.receipts.tryReceive().isFailure)
        assertTrue(room.markedUnread)
        assertTrue(conversation.markRead("\$new"))
        assertEquals(ReceiptType.READ to "\$new", timeline.receipts.receive())
        assertEquals(ReceiptType.FULLY_READ to "\$new", timeline.receipts.receive())
        assertFalse(room.markedUnread)
        assertTrue(conversation.markRead("\$new"))
        assertTrue(timeline.receipts.tryReceive().isFailure)
        assertEquals(TimelineFocus.Live(true), room.configuration?.focus)

        conversation.close()
        timeline.listenerCancelled.await()
        timeline.pageCancelled.await()
        val closed = conversation.state.value
        timeline.emit(listOf(TimelineDiff.PushBack(conversationItem("late", "\$late", "Too late"))))
        assertEquals(closed, conversation.state.value)
    }
}

private class ConversationRoom(private val value: Timeline) : Room(NoHandle) {
    var configuration: TimelineConfiguration? = null
    var markedUnread = true
    override suspend fun setUnreadFlag(newValue: Boolean) { markedUnread = newValue }
    override suspend fun timeline(): Timeline = value
    var openFailure: Exception? = null
    override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline {
        openFailure?.let { throw it }
        this.configuration = configuration
        return value
    }
}

private class ConversationTimeline(private val cached: List<TimelineItem>) : Timeline(NoHandle) {
    private var listener: TimelineListener? = null
    val page = CompletableDeferred<Boolean>()
    val pageStarted = CompletableDeferred<Unit>()
    val pageCancelled = CompletableDeferred<Unit>()
    val listenerCancelled = CompletableDeferred<Unit>()
    val receipts = Channel<Pair<ReceiptType, String>>(Channel.UNLIMITED)
    val submissions = Channel<ConversationContent>(Channel.UNLIMITED)
    val sendResults = Channel<Result<SendHandle>>(Channel.UNLIMITED)
    override suspend fun addListener(listener: TimelineListener): TaskHandle {
        this.listener = listener
        listener.onUpdate(listOf(TimelineDiff.Reset(cached)))
        return object : TaskHandle(NoHandle) { override fun cancel() { listenerCancelled.complete(Unit) } }
    }
    var pageFailure: Exception? = null
    var pages = 0
    override suspend fun paginateBackwards(numEvents: UShort): Boolean {
        pages++
        pageStarted.complete(Unit)
        pageFailure?.let { throw it }
        return try { page.await() } finally { pageCancelled.complete(Unit) }
    }
    var receiptFailure: Exception? = null
    override suspend fun sendReadReceipt(receiptType: ReceiptType, eventId: String) {
        receiptFailure?.let { throw it }
        receipts.send(receiptType to eventId)
    }
    fun emit(diff: List<TimelineDiff>) { listener?.onUpdate(diff) }
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

private fun conversationItem(
    stableId: String,
    eventId: String,
    body: String,
    local: Boolean = false,
    content: TimelineItemContent? = null,
    sender: String = "@mira:example.org",
    timestamp: ULong = 1_700_000_000_000u,
    onMap: () -> Unit = {},
): TimelineItem {
    val event = EventTimelineItem(
        isRemote = !local,
        eventOrTransactionId = if (local) EventOrTransactionId.TransactionId(eventId) else EventOrTransactionId.EventId(eventId),
        sender = sender,
        senderProfile = ProfileDetails.Ready(if (sender == "@mira:example.org") "Mira Chen" else "Sam Okafor", false, null, null, null),
        forwarder = null, forwarderProfile = null, isOwn = false, isEditable = false,
        content = content ?: TimelineItemContent.MsgLike(MsgLikeContent(
            MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent(body, null)), body, false, null)),
            null, null, null,
        )),
        reactions = emptyList(), eventTypeRaw = "m.room.message", timestamp = timestamp,
        localSendState = if (local) EventSendState.NotSentYet(null) else null, editSendState = null, redactionSendState = null, localCreatedAt = null,
        readReceipts = emptyMap(), origin = null, canBeRepliedTo = true,
        lazyProvider = object : LazyTimelineItemProvider(NoHandle) {},
    )
    return object : TimelineItem(NoHandle) {
        override fun uniqueId(): TimelineUniqueId = TimelineUniqueId(stableId)
        override fun asEvent(): EventTimelineItem = event.also { onMap() }
    }
}

private fun dateDivider(stableId: String, timestamp: ULong) = object : TimelineItem(NoHandle) {
    override fun uniqueId(): TimelineUniqueId = TimelineUniqueId(stableId)
    override fun asEvent(): EventTimelineItem? = null
    override fun asVirtual(): VirtualTimelineItem = VirtualTimelineItem.DateDivider(timestamp)
}

private val List<ConversationRow>.messages get() = filterIsInstance<ConversationMessage>()
