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

        assertEquals(listOf("\$liked", "\$reply", "\$dm", "\$mention"), activity.items.first { it.size == 4 }.map { it.eventId })
        val (liked, reply, dm, mention) = activity.items.value
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
            if (room == "!team:example.org" && event == "\$mine") "Ship it on Friday?" else null
        }
        activity.listener.onNotification(reaction("\$liked", "👍", at = 5_000u), "!team:example.org")

        val liked = activity.items.first { it.isNotEmpty() }.single()
        assertEquals("Ship it on Friday?", liked.reactedTo)
        assertTrue(liked.unread)
        activity.markRead(liked.id)
        assertFalse(activity.items.value.single().unread)
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
}

private fun notification(eventId: String, body: String, at: ULong, mention: Boolean = false, thread: String? = null,
    direct: Boolean = false, sender: String = "@sam:example.org") =
    item(eventId, at, sender, TimelineEventContent.MessageLike(MessageLikeEventContent.RoomMessage(
        MessageType.Text(TextMessageContent(body, null)), null)), "{}", mention, thread, direct)

private fun reaction(eventId: String, key: String, at: ULong) = item(eventId, at, "@sam:example.org",
    TimelineEventContent.MessageLike(MessageLikeEventContent.ReactionContent("\$mine")),
    """{"type":"m.reaction","content":{"m.relates_to":{"rel_type":"m.annotation","event_id":"${'$'}mine","key":"$key"}}}""",
    mention = false, thread = null, direct = false)

private fun item(eventId: String, at: ULong, sender: String, content: TimelineEventContent, raw: String, mention: Boolean,
    thread: String?, direct: Boolean) = NotificationItem(
    event = NotificationEvent.Timeline(object : TimelineEvent(NoHandle) {
        override fun content(): TimelineEventContent = content
        override fun eventId(): String = eventId
        override fun senderId(): String = sender
        override fun timestamp(): ULong = at
        override fun threadRootEventId(): String? = thread
    }),
    rawEvent = raw, senderInfo = NotificationSenderInfo("Sam", "mxc://example.org/sam", false),
    roomInfo = NotificationRoomInfo(if (direct) "Sam" else "Team", null, null, null, null, 2u, 0u, emptyList(), true, direct, false, direct),
    isNoisy = true, hasMention = mention, threadId = thread, actions = null,
)
