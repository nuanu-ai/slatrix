package ai.nuanu.slatrix.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONObject
import org.matrix.rustcomponents.sdk.MessageLikeEventContent
import org.matrix.rustcomponents.sdk.MessageType
import org.matrix.rustcomponents.sdk.NotificationEvent
import org.matrix.rustcomponents.sdk.NotificationItem
import org.matrix.rustcomponents.sdk.SyncNotificationListener
import org.matrix.rustcomponents.sdk.TimelineEventContent

enum class ActivityKind { Mention, ThreadReply, Reaction, Message }

data class ActivityItem(
    val id: String,
    val roomId: String,
    val eventId: String,
    val roomName: String,
    val direct: Boolean,
    val senderName: String,
    val initials: String,
    val colorIndex: Int,
    val body: String,
    val timestamp: Long,
    val kind: ActivityKind,
    val threadRoot: String?,
)

private const val MAX_ITEMS = 300

/**
 * What the SDK says notified you, newest first, as on the Mac: the events sync and pushes deliver while the app runs.
 * Reactions show when a push rule lets them notify.
 */
class MatrixActivity(private val userId: String) {
    private val mutableItems = MutableStateFlow<List<ActivityItem>>(emptyList())
    val items: StateFlow<List<ActivityItem>> = mutableItems.asStateFlow()

    val listener = object : SyncNotificationListener {
        override fun onNotification(notification: NotificationItem, roomId: String) {
            try { receive(notification, roomId) } finally { notification.destroy() }
        }
    }

    fun receive(notification: NotificationItem, roomId: String) {
        val event = (notification.event as? NotificationEvent.Timeline)?.event ?: return
        val item = runCatching {
            val sender = event.senderId()
            if (sender == userId) return
            val content = (event.content() as? TimelineEventContent.MessageLike)?.content ?: return
            val thread = notification.threadId ?: event.threadRootEventId()
            val body = when (content) {
                is MessageLikeEventContent.RoomMessage -> when (val type = content.messageType) {
                    is MessageType.Text -> type.content.body
                    is MessageType.Notice -> type.content.body
                    is MessageType.Emote -> type.content.body
                    else -> "Shared a file"
                }
                is MessageLikeEventContent.ReactionContent -> JSONObject(notification.rawEvent).optJSONObject("content")
                    ?.optJSONObject("m.relates_to")?.optString("key").orEmpty()
                is MessageLikeEventContent.Sticker -> "Shared a sticker"
                is MessageLikeEventContent.Poll -> content.question
                is MessageLikeEventContent.RoomEncrypted -> "Waiting for this message"
                else -> return
            }
            val senderName = notification.senderInfo.displayName?.takeIf { it.isNotBlank() } ?: sender
            ActivityItem(
                id = "$roomId ${event.eventId()}", roomId = roomId, eventId = event.eventId(),
                roomName = notification.roomInfo.displayName, direct = notification.roomInfo.isDirect,
                senderName = senderName, initials = AvatarPlaceholder.initials(senderName),
                colorIndex = AvatarPlaceholder.colorIndex(senderName), body = body.take(4096),
                timestamp = event.timestamp().coerceAtMost(Long.MAX_VALUE.toULong()).toLong(),
                kind = when {
                    content is MessageLikeEventContent.ReactionContent -> ActivityKind.Reaction
                    notification.hasMention == true -> ActivityKind.Mention
                    thread != null -> ActivityKind.ThreadReply
                    else -> ActivityKind.Message
                },
                threadRoot = thread,
            )
        }.getOrNull() ?: return
        mutableItems.update { current ->
            // A later decryption of the same event replaces it in place.
            (current.filterNot { it.id == item.id } + item)
                .sortedWith(compareByDescending<ActivityItem> { it.timestamp }.thenBy { it.id }).take(MAX_ITEMS)
        }
    }
}
