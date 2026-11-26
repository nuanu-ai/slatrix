package ai.nuanu.slatrix.core

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.matrix.rustcomponents.sdk.*

// Robolectric, for the platform JSON parser that reads a reaction's key.
@RunWith(RobolectricTestRunner::class)
@Config(application = android.app.Application::class, sdk = [35])
class MatrixActivityTest {
    // capability: activity.feed
    @Test fun syncNotificationsBecomeTheNewestFirstFeedWithoutOwnOrRepeatedEvents() = runTest {
        val activity = MatrixActivity("@alex:example.org", backgroundScope) { _, _ -> null }
        activity.listener.onNotification(notification("\$mention", "Can you review?", at = 1_000u, mention = true), "!team:example.org")
        activity.listener.onNotification(notification("\$reply", "Agreed", at = 3_000u, thread = "\$root"), "!team:example.org")
        activity.listener.onNotification(notification("\$dm", "Lunch?", at = 2_000u, direct = true), "!sam:example.org")
        activity.listener.onNotification(notification("\$own", "Mine", at = 4_000u, sender = "@alex:example.org"), "!team:example.org")
        activity.listener.onNotification(notification("\$mention", "Can you review?", at = 1_000u, mention = true), "!team:example.org")
        activity.listener.onNotification(reaction("\$liked", "👍", at = 5_000u), "!team:example.org")

        assertEquals(listOf("\$mine", "\$reply", "\$dm", "\$mention"), activity.items.first { it.size == 4 }.map { it.eventId })
        val (liked, reply, dm, mention) = activity.items.value
        assertEquals("!team:example.org \$liked", liked.id)
        assertEquals(ActivityKind.Reaction, liked.kind)
        assertEquals("👍", liked.body)
        assertEquals(ActivityKind.ThreadReply, reply.kind)
        assertEquals("\$root", reply.threadRoot)
        assertEquals(ActivityKind.Message, dm.kind)
        assertEquals(true, dm.direct)
        assertEquals(ActivityKind.Mention, mention.kind)
        assertEquals("Team", mention.roomName)
        assertEquals("Sam", mention.senderName)
        assertEquals("mxc://example.org/sam", mention.avatarUrl)
        assertEquals("Can you review?", mention.body)
    }

    // capability: activity.feed
    @Test fun aReactionShowsTheMessageItReactedToAndAnItemStaysUnreadUntilOpened() = runTest {
        val activity = MatrixActivity("@alex:example.org", backgroundScope) { room, event ->
            if (room == "!team:example.org" && event == "\$mine") ReactedEvent("Ship it on Friday?") else null
        }
        activity.listener.onNotification(reaction("\$liked", "👍", at = 5_000u), "!team:example.org")

        val liked = activity.items.first { it.isNotEmpty() }.single()
        assertEquals("\$mine", liked.eventId)
        assertEquals("!team:example.org \$liked", liked.id)
        assertEquals("Ship it on Friday?", liked.reactedTo)
        assertTrue(liked.unread)
        activity.markRead(liked.id)
        assertFalse(activity.items.value.single().unread)
    }

    // capability: activity.open-item
    @Test fun reactionsOnAThreadReplyTargetThatReplyInItsThreadWithoutColliding() = runTest {
        val activity = MatrixActivity("@alex:example.org", backgroundScope) { room, event ->
            if (room == "!team:example.org" && event == "\$reply") ReactedEvent("Ship it on Friday?", threadRoot = "\$root") else null
        }
        activity.listener.onNotification(reaction("\$r1", "👍", at = 5_000u, related = "\$reply"), "!team:example.org")
        activity.listener.onNotification(reaction("\$r2", "🔥", at = 6_000u, related = "\$reply"), "!team:example.org")

        val items = activity.items.first { it.size == 2 }
        assertEquals(listOf("!team:example.org \$r2", "!team:example.org \$r1"), items.map { it.id })
        assertEquals(listOf("\$reply", "\$reply"), items.map { it.eventId })
        assertEquals(listOf("\$root", "\$root"), items.map { it.threadRoot })
        assertEquals(listOf("Ship it on Friday?", "Ship it on Friday?"), items.map { it.reactedTo })
    }

    @Test fun reactedEventReadsBothMessageTextAndThreadRootFromTheRoom() = runTest {
        val client = object : Client(NoHandle) {
            override fun getRoom(roomId: String): Room? = if (roomId != "!team:example.org") null else object : Room(NoHandle) {
                override suspend fun loadOrFetchEvent(eventId: String): TimelineEvent = object : TimelineEvent(NoHandle) {
                    override fun content(): TimelineEventContent = TimelineEventContent.MessageLike(
                        MessageLikeEventContent.RoomMessage(MessageType.Text(TextMessageContent("In thread", null)), null))
                    override fun threadRootEventId(): String = "\$root"
                }
            }
        }
        assertEquals(ReactedEvent("In thread", "\$root"), reactedEvent(client, "!team:example.org", "\$reply"))
    }

    // capability: activity.feed
    @Test fun aReplyShowsItsOwnTextHoweverLongTheMessageItQuotes() = runTest {
        val activity = MatrixActivity("@alex:example.org", backgroundScope) { _, _ -> null }
        val quoted = "> <@bob:example.org> " + "Earlier ".repeat(600) + "\n> and more\n\nMy reply"
        activity.listener.onNotification(notification("\$reply", quoted, at = 1_000u, replyTo = "\$earlier"), "!team:example.org")

        assertEquals("My reply", activity.items.first { it.isNotEmpty() }.single().body)
    }

    // capability: activity.badge
    @Test fun openingAThreadMarksItsRepliesReadAndNoOtherThreads() = runTest {
        val activity = MatrixActivity("@alex:example.org", backgroundScope) { _, _ -> null }
        activity.listener.onNotification(notification("\$one", "Agreed", at = 1_000u, thread = "\$root"), "!team:example.org")
        activity.listener.onNotification(notification("\$two", "Me too", at = 2_000u, thread = "\$root"), "!team:example.org")
        activity.listener.onNotification(notification("\$other", "Later", at = 3_000u, thread = "\$elsewhere"), "!team:example.org")
        activity.listener.onNotification(notification("\$same", "Hi", at = 4_000u, thread = "\$root"), "!design:example.org")
        activity.items.first { it.size == 4 }

        activity.markThreadRead("!team:example.org", "\$root")
        assertEquals(listOf("\$same", "\$other"), activity.items.value.filter { it.unread }.map { it.eventId })
    }

    // capability: activity.badge
    @Test fun markingARoomReadClearsItsThreadRepliesAndNoOtherRooms() = runTest {
        val activity = MatrixActivity("@alex:example.org", backgroundScope) { _, _ -> null }
        activity.listener.onNotification(notification("\$one", "Agreed", at = 1_000u, thread = "\$root"), "!team:example.org")
        activity.listener.onNotification(notification("\$two", "Later", at = 2_000u, thread = "\$elsewhere"), "!team:example.org")
        activity.listener.onNotification(notification("\$otherRoom", "Hi", at = 3_000u, thread = "\$root"), "!design:example.org")
        activity.items.first { it.size == 3 }

        activity.markRoomRead("!team:example.org")
        assertEquals(listOf("\$otherRoom"), activity.items.value.filter { it.unread }.map { it.eventId })
    }

    // capability: activity.badge
    @Test fun markingRoomMessagesReadPermanentlyClearsNonThreadItemsWithoutClearingThreadReplies() = runTest {
        val activity = MatrixActivity("@alex:example.org", backgroundScope) { _, _ -> null }
        activity.listener.onNotification(notification("\$mention", "Ping", at = 1_000u, mention = true), "!team:example.org")
        activity.listener.onNotification(reaction("\$liked", "👍", at = 2_000u), "!team:example.org")
        activity.listener.onNotification(notification("\$reply", "In thread", at = 3_000u, thread = "\$root"), "!team:example.org")
        activity.listener.onNotification(notification("\$other", "Elsewhere", at = 4_000u, mention = true), "!design:example.org")
        activity.items.first { it.size == 4 }

        activity.markRoomMessagesRead("!team:example.org")
        assertEquals(listOf("\$other", "\$reply"), activity.items.value.filter { it.unread }.map { it.eventId })

        // A later unread mention in the same room must not resurrect the earlier read mention.
        val unreadTeam = listOf(RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.Count("1"), "T", 0, mentions = 1))
        assertEquals(listOf("\$other", "\$reply"), activity.items.value.readWith(unreadTeam).filter { it.unread }.map { it.eventId })
    }

    // capability: activity.badge
    @Test fun markingRoomMentionsReadPermanentlyClearsMentionsWithoutClearingMessagesOrThreads() = runTest {
        val activity = MatrixActivity("@alex:example.org", backgroundScope) { _, _ -> null }
        activity.listener.onNotification(notification("\$mention", "Ping", at = 1_000u, mention = true), "!team:example.org")
        activity.listener.onNotification(notification("\$threadMention", "Thread ping", at = 1_500u, mention = true, thread = "\$root"), "!team:example.org")
        activity.listener.onNotification(notification("\$dm", "Normal", at = 2_000u), "!team:example.org")
        activity.listener.onNotification(notification("\$newerMention", "Newer ping", at = 5_000u, mention = true), "!team:example.org")
        activity.listener.onNotification(notification("\$reply", "In thread", at = 3_000u, thread = "\$root"), "!team:example.org")
        activity.items.first { it.size == 5 }

        activity.markRoomMentionsRead("!team:example.org", throughTimestamp = 2_500L)
        // `$mention` clears; `$threadMention` (in thread), `$newerMention` (after cutoff), `$dm`, and `$reply` stay unread.
        assertEquals(listOf("\$newerMention", "\$reply", "\$dm", "\$threadMention"),
            activity.items.value.filter { it.unread }.map { it.eventId })

        val laterMention = listOf(RoomSummary("!team:example.org", "Team", false, "", UnreadBadge.Count("1"), "T", 0, mentions = 1))
        assertEquals(listOf("\$newerMention", "\$reply", "\$dm", "\$threadMention"),
            activity.items.value.readWith(laterMention).filter { it.unread }.map { it.eventId })
    }

    // capability: activity.badge
    @Test fun reconcileReceiptsClearsThreadRepliesAndReactionsCoveredByServerReceipts() = runTest {
        val receipts = mutableMapOf<Pair<ReceiptType, ReceiptThread>, UserReceipt>(
            (ReceiptType.READ to ReceiptThread.Main) to UserReceipt("\$mine", Receipt(1_000u)),
            (ReceiptType.READ to ReceiptThread.Thread("\$root")) to UserReceipt("\$r1", Receipt(2_500u)),
            // Uncached target event `$missing` with a high client receipt timestamp must NOT clear newer items.
            (ReceiptType.READ to ReceiptThread.Thread("\$other")) to UserReceipt("\$missing", Receipt(9_999u)),
        )
        val timestamps = mapOf("\$mine" to 1_000uL, "\$r1" to 2_000uL, "\$newer" to 4_000uL)
        val client = object : Client(NoHandle) {
            override fun getRoom(roomId: String): Room? = if (roomId != "!team:example.org") null else object : Room(NoHandle) {
                override suspend fun loadUserReceipt(receiptType: ReceiptType, thread: ReceiptThread, userId: String): UserReceipt? =
                    receipts[receiptType to thread]
                override suspend fun loadOrFetchEvent(eventId: String): TimelineEvent {
                    val ts = timestamps[eventId] ?: throw IllegalStateException("event not found")
                    return object : TimelineEvent(NoHandle) {
                        override fun timestamp(): ULong = ts
                    }
                }
            }
        }
        val activity = MatrixActivity("@alex:example.org", backgroundScope) { _, _ -> null }
        activity.listener.onNotification(notification("\$r1", "Read in thread", at = 2_000u, thread = "\$root"), "!team:example.org")
        // Older than `$r1` (1500ms < 2000ms) in an unrelated thread, proving `$root`'s receipt stays thread-scoped.
        activity.listener.onNotification(notification("\$r2", "Other thread", at = 1_500u, thread = "\$other"), "!team:example.org")
        activity.listener.onNotification(reaction("\$rx", "👍", at = 3_000u, related = "\$mine"), "!team:example.org")
        activity.items.first { it.size == 3 }

        activity.reconcileReceipts(client)
        // `$r1` is cleared by its thread receipt; `$r2` and the 3000ms reaction on `$mine` remain unread.
        assertEquals(listOf("\$mine", "\$r2"), activity.items.value.filter { it.unread }.map { it.eventId })

        // Private unthreaded receipt at 4000ms covers both `$r2` and the 3000ms reaction.
        receipts[ReceiptType.READ_PRIVATE to ReceiptThread.Unthreaded] = UserReceipt("\$newer", Receipt(4_000u))
        activity.reconcileReceipts(client, setOf("!team:example.org"))
        assertTrue(activity.items.value.none { it.unread })
    }

    // capability: people.names
    @Test fun aMentionReadsAsThePeopleItNamesAndASenderWithoutANameByTheirLocalpart() = runTest {
        val activity = MatrixActivity("@alex:example.org", backgroundScope, memberNames = { room, ids ->
            if (room == "!team:example.org") mapOf("@mira:example.org" to "Mira Chen").filterKeys { it in ids } else emptyMap()
        }) { _, _ -> null }
        activity.listener.onNotification(notification("\$ask", "@mira:example.org and @kai:example.org, can you look?",
            at = 1_000u, sender = "@sam:example.org", senderName = null), "!team:example.org")

        val ask = activity.items.first { it.isNotEmpty() }.single()
        assertEquals("@Mira Chen and @kai, can you look?", ask.body)
        assertEquals("sam", ask.senderName)
    }
}

class ActivityWorkspaceTest {
    // capability: activity.feed
    @Test fun aWorkspaceShowsItsChannelsAndEveryDmButNotOtherWorkspacesOrUnknownRooms() {
        fun item(roomId: String) = ActivityItem("$roomId \$e", roomId, "\$e", "", false, "Sam", "S", 0, "Hi", 0, ActivityKind.Message, null)
        fun room(id: String, direct: Boolean, space: String?) =
            RoomSummary(id, id, direct, "", UnreadBadge.None, "R", 0, setOfNotNull(space))
        val rooms = listOf(room("!ours", false, "!studio"), room("!theirs", false, "!other"), room("!dm", true, null))
        val items = listOf(item("!ours"), item("!theirs"), item("!dm"), item("!left"))

        assertEquals(listOf("!ours", "!dm"), items.inWorkspace(rooms, "!studio").map { it.roomId })
        assertEquals(listOf("!ours", "!theirs", "!dm"), items.inWorkspace(rooms, null).map { it.roomId })
    }

    @Test fun aMentionReadInItsConversationReadsInActivityButAThreadReplyWaitsToBeOpened() {
        fun item(id: String, kind: ActivityKind, root: String? = null) =
            ActivityItem(id, "!team", "\$$id", "", false, "Sam", "S", 0, "Hi", 0, kind, root)
        val items = listOf(
            item("mention", ActivityKind.Mention),
            item("message", ActivityKind.Message),
            item("reply", ActivityKind.ThreadReply, "\$root"),
        )
        fun room(unread: UnreadBadge, mentions: Long = 0) =
            listOf(RoomSummary("!team", "team", false, "", unread, "T", 0, emptySet(), mentions = mentions))

        assertEquals(listOf(false, false, true), items.readWith(room(UnreadBadge.None)).map { it.unread })
        assertEquals(listOf(false, true, true), items.readWith(room(UnreadBadge.Bold, mentions = 0)).map { it.unread })
        assertEquals(listOf(true, true, true), items.readWith(room(UnreadBadge.Count("1"), mentions = 1)).map { it.unread })
    }
}

private fun notification(eventId: String, body: String, at: ULong, mention: Boolean = false, thread: String? = null,
    direct: Boolean = false, sender: String = "@sam:example.org", senderName: String? = "Sam", replyTo: String? = null) =
    item(eventId, at, sender, TimelineEventContent.MessageLike(MessageLikeEventContent.RoomMessage(
        MessageType.Text(TextMessageContent(body, null)), replyTo)), "{}", mention, thread, direct, senderName)

private fun reaction(eventId: String, key: String, at: ULong, related: String = "\$mine") = item(eventId, at, "@sam:example.org",
    TimelineEventContent.MessageLike(MessageLikeEventContent.ReactionContent(related)),
    """{"type":"m.reaction","content":{"m.relates_to":{"rel_type":"m.annotation","event_id":"$related","key":"$key"}}}""",
    mention = false, thread = null, direct = false)

private fun item(eventId: String, at: ULong, sender: String, content: TimelineEventContent, raw: String, mention: Boolean,
    thread: String?, direct: Boolean, senderName: String? = "Sam") = NotificationItem(
    event = NotificationEvent.Timeline(object : TimelineEvent(NoHandle) {
        override fun content(): TimelineEventContent = content
        override fun eventId(): String = eventId
        override fun senderId(): String = sender
        override fun timestamp(): ULong = at
        override fun threadRootEventId(): String? = thread
    }),
    rawEvent = raw, senderInfo = NotificationSenderInfo(senderName, "mxc://example.org/sam", false),
    roomInfo = NotificationRoomInfo(if (direct) "Sam" else "Team", null, null, null, null, 2u, 0u, emptyList(), true, direct, false, direct),
    isNoisy = true, hasMention = mention, threadId = thread, actions = null,
)
