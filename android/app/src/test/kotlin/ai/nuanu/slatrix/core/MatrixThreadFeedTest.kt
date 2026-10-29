package ai.nuanu.slatrix.core

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.matrix.rustcomponents.sdk.*

class MatrixThreadFeedTest {
    // capability: threads.feed
    @Test fun listsTheThreadsYoureInByLatestActivityAndMarksTheOnesWithUnreadReplies() = runTest {
        val design = FeedRoom("!design:example.org", listOf(
            thread(root = event("\$started", "@alex:example.org", 1u, "Shall we ship?"),
                latest = event("\$answer", "@sam:example.org", 50u, "Yes, Friday")),
            thread(root = event("\$read", "@sam:example.org", 2u, "Budget?"),
                latest = event("\$read-reply", "@mira:example.org", 40u, "Approved")),
            thread(root = event("\$elsewhere", "@sam:example.org", 3u, "Lunch plans"),
                latest = event("\$elsewhere-reply", "@mira:example.org", 60u, "Pizza")),
        ), receipts = mapOf("\$read" to UserReceipt("\$read-reply", Receipt(40u))))
        val direct = FeedRoom("!sam:example.org", listOf(
            thread(root = event("\$asked", "@sam:example.org", 4u, "Review?"),
                latest = event("\$replied", "@alex:example.org", 45u, "Done")),
        ), receipts = mapOf("\$asked" to UserReceipt("\$replied", Receipt(45u))))
        val client = object : Client(NoHandle) {
            override fun getRoom(roomId: String): Room? = listOf(design, direct).firstOrNull { it.roomId == roomId }
        }
        val rooms = listOf(
            RoomSummary(design.roomId, "design", false, "", UnreadBadge.None, "D", 0),
            RoomSummary(direct.roomId, "Sam", true, "", UnreadBadge.None, "S", 1),
        )
        val feed = MatrixThreadFeed(backgroundScope, client, "@alex:example.org", rooms)

        val items = feed.state.first { !it.loading }.items
        assertEquals("A thread you never joined stays out", listOf("\$started", "\$asked", "\$read"), items.map { it.rootId })
        assertEquals(listOf(true, false, false), items.map { it.unread })
        val started = items.first()
        assertEquals("design", started.roomName)
        assertEquals("Shall we ship?", started.root.body)
        assertEquals("Yes, Friday", started.latest?.body)
        assertEquals(3, started.replies)

        direct.change(listOf(thread(root = event("\$asked", "@sam:example.org", 4u, "Review?"),
            latest = event("\$again", "@sam:example.org", 70u, "One more thing"))))
        val live = feed.state.first { it.items.first().rootId == "\$asked" }.items.first()
        assertEquals("A new reply moves its thread up, unread", true, live.unread)
        assertEquals("One more thing", live.latest?.body)
    }
}

private class FeedRoom(val roomId: String, private val threads: List<ThreadListItem>,
    private val receipts: Map<String, UserReceipt> = emptyMap()) : Room(NoHandle) {
    private var loaded = emptyList<ThreadListItem>()
    private var listener: ThreadListEntriesListener? = null
    fun change(threads: List<ThreadListItem>) {
        loaded = threads
        listener?.onUpdate(emptyList())
    }
    override fun id(): String = roomId
    override fun threadListService(): ThreadListService = object : ThreadListService(NoHandle) {
        override fun items(): List<ThreadListItem> = loaded
        override suspend fun paginate() { loaded = threads }
        override fun subscribeToItemsUpdates(listener: ThreadListEntriesListener): TaskHandle {
            this@FeedRoom.listener = listener
            return object : TaskHandle(NoHandle) { override fun cancel() = Unit }
        }
    }
    override suspend fun loadUserReceipt(receiptType: ReceiptType, thread: ReceiptThread, userId: String): UserReceipt? =
        receipts[(thread as ReceiptThread.Thread).threadRootEventId]
}

private fun thread(root: ThreadListItemEvent, latest: ThreadListItemEvent) = ThreadListItem(root, latest, 3u)

private fun event(id: String, sender: String, at: ULong, body: String) = ThreadListItemEvent(
    eventId = id, timestamp = at, sender = sender,
    senderProfile = ProfileDetails.Ready(sender.drop(1).substringBefore(':').replaceFirstChar { it.uppercase() }, false, null, null, null),
    isOwn = sender == "@alex:example.org",
    content = TimelineItemContent.MsgLike(MsgLikeContent(
        MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent(body, null)), body, false, null)), null, null, null)),
)
