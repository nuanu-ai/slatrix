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
            // Your reply from another device, before its receipt arrives, leaves its thread read.
            thread(root = event("\$offsite", "@sam:example.org", 5u, "Venue?"),
                latest = event("\$booked", "@alex:example.org", 30u, "Booked")),
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
        assertEquals("A thread you never joined stays out", listOf("\$started", "\$asked", "\$read", "\$offsite"), items.map { it.rootId })
        assertEquals(listOf(true, false, false, false), items.map { it.unread })
        val started = items.first()
        assertEquals("design", started.roomName)
        assertEquals("Shall we ship?", started.root.body)
        assertEquals("Yes, Friday", started.latest?.body)
        assertEquals("Each message brings its sender's picture", "mxc://example.org/sam", started.latest?.avatarUrl)
        assertEquals(3, started.replies)

        direct.change(listOf(thread(root = event("\$asked", "@sam:example.org", 4u, "Review?"),
            latest = event("\$again", "@sam:example.org", 70u, "One more thing"))))
        val live = feed.state.first { it.items.first().rootId == "\$asked" }.items.first()
        assertEquals("A new reply moves its thread up, unread", true, live.unread)
        assertEquals("One more thing", live.latest?.body)
    }

    // capability: threads.feed
    @Test fun anUnthreadedRoomReceiptClearsThreadUnreadWithoutListingUnjoinedThreads() = runTest {
        val design = FeedRoom("!design:example.org", listOf(
            thread(root = event("\$started", "@alex:example.org", 1u, "Shall we ship?"),
                latest = event("\$answer", "@sam:example.org", 50u, "Yes, Friday")),
            thread(root = event("\$elsewhere", "@sam:example.org", 3u, "Lunch plans"),
                latest = event("\$elsewhere-reply", "@mira:example.org", 60u, "Pizza")),
        ))
        val client = object : Client(NoHandle) {
            override fun getRoom(roomId: String): Room? = design.takeIf { it.roomId == roomId }
        }
        val feed = MatrixThreadFeed(backgroundScope, client, "@alex:example.org",
            listOf(RoomSummary(design.roomId, "design", false, "", UnreadBadge.Bold, "D", 0)))

        val initial = feed.state.first { !it.loading }.items
        assertEquals(listOf("\$started"), initial.map { it.rootId })
        assertEquals(listOf(true), initial.map { it.unread })

        design.unthreadedReceipt = UserReceipt("\$room-latest", Receipt(60u))
        feed.refresh(design.roomId)
        val cleared = feed.state.first { it.items.singleOrNull()?.unread == false }.items
        assertEquals("An unthreaded receipt must not pull in unjoined threads", listOf("\$started"), cleared.map { it.rootId })
        assertEquals(listOf(false), cleared.map { it.unread })
    }

    // capability: threads.feed
    @Test fun markingAThreadOrRoomReadClearsUnreadImmediatelyAndReArmsOnNewReplies() = runTest {
        val design = FeedRoom("!design:example.org", listOf(
            thread(root = event("\$started", "@alex:example.org", 1u, "Shall we ship?"),
                latest = event("\$answer", "@sam:example.org", 50u, "Yes, Friday")),
        ))
        val client = object : Client(NoHandle) {
            override fun getRoom(roomId: String): Room? = design.takeIf { it.roomId == roomId }
        }
        val feed = MatrixThreadFeed(backgroundScope, client, "@alex:example.org",
            listOf(RoomSummary(design.roomId, "design", false, "", UnreadBadge.Bold, "D", 0)))
        assertEquals(true, feed.state.first { !it.loading }.items.single().unread)

        feed.markThreadRead(design.roomId, "\$started", "\$answer")
        assertEquals(false, feed.state.first { !it.items.single().unread }.items.single().unread)

        design.change(listOf(thread(root = event("\$started", "@alex:example.org", 1u, "Shall we ship?"),
            latest = event("\$followup", "@sam:example.org", 70u, "Follow up"))))
        val next = feed.state.first { it.items.single().latest?.body == "Follow up" }.items.single()
        assertEquals(true, next.unread)

        feed.markRoomRead(design.roomId)
        assertEquals(false, feed.state.first { !it.items.single().unread }.items.single().unread)
    }

    // capability: threads.feed
    @Test fun anUnthreadedReceiptSentLaterOnAnEarlierEventDoesNotClearANewerThreadReply() = runTest {
        val design = FeedRoom("!design:example.org", listOf(
            thread(root = event("\$started", "@alex:example.org", 1u, "Shall we ship?"),
                latest = event("\$answer", "@sam:example.org", 50u, "Yes, Friday")),
        ), eventTimestamps = mapOf("\$earlier" to 10u, "\$room-latest" to 60u))
        // Receipt was sent at t=80 (after reply at t=50), but points to an older room event from t=10.
        design.unthreadedReceipt = UserReceipt("\$earlier", Receipt(80u))
        val client = object : Client(NoHandle) {
            override fun getRoom(roomId: String): Room? = design.takeIf { it.roomId == roomId }
        }
        val feed = MatrixThreadFeed(backgroundScope, client, "@alex:example.org",
            listOf(RoomSummary(design.roomId, "design", false, "", UnreadBadge.Bold, "D", 0)))

        assertEquals(true, feed.state.first { !it.loading }.items.single().unread)

        design.unthreadedReceipt = UserReceipt("\$room-latest", Receipt(80u))
        feed.refresh(design.roomId)
        assertEquals(false, feed.state.first { !it.items.single().unread }.items.single().unread)
    }
}

private class FeedRoom(val roomId: String, private val threads: List<ThreadListItem>,
    private val receipts: Map<String, UserReceipt> = emptyMap(),
    private val eventTimestamps: Map<String, ULong> = emptyMap()) : Room(NoHandle) {
    @Volatile var unthreadedReceipt: UserReceipt? = null
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
    override suspend fun loadOrFetchEvent(eventId: String): TimelineEvent {
        val ts = eventTimestamps[eventId] ?: throw IllegalStateException("Unknown event $eventId")
        return object : TimelineEvent(NoHandle) {
            override fun timestamp(): ULong = ts
        }
    }
    override suspend fun loadUserReceipt(receiptType: ReceiptType, thread: ReceiptThread, userId: String): UserReceipt? =
        when (thread) {
            is ReceiptThread.Thread -> receipts[thread.threadRootEventId]
            ReceiptThread.Unthreaded -> unthreadedReceipt
            else -> null
        }
}

private fun thread(root: ThreadListItemEvent, latest: ThreadListItemEvent) = ThreadListItem(root, latest, 3u)

private fun event(id: String, sender: String, at: ULong, body: String) = ThreadListItemEvent(
    eventId = id, timestamp = at, sender = sender,
    senderProfile = ProfileDetails.Ready(sender.drop(1).substringBefore(':').replaceFirstChar { it.uppercase() }, false,
        "mxc://example.org/" + sender.drop(1).substringBefore(':'), null, null),
    isOwn = sender == "@alex:example.org",
    content = TimelineItemContent.MsgLike(MsgLikeContent(
        MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent(body, null)), body, false, null)), null, null, null)),
)
