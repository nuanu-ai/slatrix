package ai.nuanu.slatrix.core

import org.junit.Assert.assertEquals
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
    @Test fun syncNotificationsBecomeTheNewestFirstFeedWithoutOwnOrRepeatedEvents() {
        val activity = MatrixActivity("@alex:example.org")
        activity.listener.onNotification(notification("\$mention", "Can you review?", at = 1_000u, mention = true), "!team:example.org")
        activity.listener.onNotification(notification("\$reply", "Agreed", at = 3_000u, thread = "\$root"), "!team:example.org")
        activity.listener.onNotification(notification("\$dm", "Lunch?", at = 2_000u, direct = true), "!sam:example.org")
        activity.listener.onNotification(notification("\$own", "Mine", at = 4_000u, sender = "@alex:example.org"), "!team:example.org")
        activity.listener.onNotification(notification("\$mention", "Can you review?", at = 1_000u, mention = true), "!team:example.org")
        activity.listener.onNotification(reaction("\$liked", "👍", at = 5_000u), "!team:example.org")

        assertEquals(listOf("\$liked", "\$reply", "\$dm", "\$mention"), activity.items.value.map { it.eventId })
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
        assertEquals("Can you review?", mention.body)
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
    rawEvent = raw, senderInfo = NotificationSenderInfo("Sam", null, false),
    roomInfo = NotificationRoomInfo(if (direct) "Sam" else "Team", null, null, null, null, 2u, 0u, emptyList(), true, direct, false, direct),
    isNoisy = true, hasMention = mention, threadId = thread, actions = null,
)
