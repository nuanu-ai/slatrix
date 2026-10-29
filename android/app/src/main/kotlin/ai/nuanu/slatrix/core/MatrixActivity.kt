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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
import kotlinx.coroutines.launch

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
    /** For a reaction, the text of the message it reacted to. */
    val reactedTo: String? = null,
    /** Not opened yet, so Slack tints it. */
    val unread: Boolean = true,
)

private const val MAX_ITEMS = 300
private const val LOOKUP_MILLIS = 10_000L

/** The items from [rooms] in workspace [spaceId], as the Mac scopes Activity; a room no longer listed drops out. */
fun List<ActivityItem>.inWorkspace(rooms: List<RoomSummary>, spaceId: String?): List<ActivityItem> {
    val inScope = rooms.filter { WorkspaceMembership.includes(it.direct, it.spaceIds, spaceId) }.mapTo(HashSet()) { it.id }
    return filter { it.roomId in inScope }
}

/**
 * What the SDK says notified you, newest first, as on the Mac: the events sync and pushes deliver while the app runs.
 * Reactions show when a push rule lets them notify.
 */
class MatrixActivity(private val userId: String, scope: CoroutineScope,
    /** The text of a room's message, for the one a reaction reacted to; null when it can't be read. */
    private val messageText: suspend (roomId: String, eventId: String) -> String?) {
    /** Its lookups end with the account it belongs to. */
    private val lookups = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    private val mutableItems = MutableStateFlow<List<ActivityItem>>(emptyList())
    val items: StateFlow<List<ActivityItem>> = mutableItems.asStateFlow()

    val listener = object : SyncNotificationListener {
        override fun onNotification(notification: NotificationItem, roomId: String) {
            try { receive(notification, roomId) } finally { notification.destroy() }
        }
    }

    fun receive(notification: NotificationItem, roomId: String) {
        val event = (notification.event as? NotificationEvent.Timeline)?.event ?: return
        var reactedTo: String? = null
        val item = runCatching {
            val sender = event.senderId()
            if (sender == userId) return
            val content = (event.content() as? TimelineEventContent.MessageLike)?.content ?: return
            val thread = notification.threadId ?: event.threadRootEventId()
            val body = when (content) {
                is MessageLikeEventContent.RoomMessage -> text(content) ?: "Shared a file"
                is MessageLikeEventContent.ReactionContent -> {
                    reactedTo = content.relatedEventId
                    JSONObject(notification.rawEvent).optJSONObject("content")?.optJSONObject("m.relates_to")?.optString("key").orEmpty()
                }
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
        val message = reactedTo ?: return add(item)
        // A reaction lands with the message it reacted to, so its row doesn't grow later; one the server is slow to give
        // lands without it.
        lookups.launch { add(item.copy(reactedTo = withTimeoutOrNull(LOOKUP_MILLIS) { messageText(roomId, message) })) }
    }

    fun close() = lookups.cancel()

    fun markRead(id: String) = mutableItems.update { current -> current.map { if (it.id == id) it.copy(unread = false) else it } }

    private fun add(item: ActivityItem) {
        mutableItems.update { current ->
            // A later decryption of the same event replaces it in place, read if it was.
            val previous = current.firstOrNull { it.id == item.id }
            // A second delivery whose lookup failed keeps the text the first found.
            (current.filterNot { it.id == item.id } +
                item.copy(unread = previous?.unread ?: item.unread, reactedTo = item.reactedTo ?: previous?.reactedTo))
                .sortedWith(compareByDescending<ActivityItem> { it.timestamp }.thenBy { it.id }).take(MAX_ITEMS)
        }
    }
}

private fun text(content: MessageLikeEventContent.RoomMessage): String? = when (val type = content.messageType) {
    is MessageType.Text -> type.content.body
    is MessageType.Notice -> type.content.body
    is MessageType.Emote -> type.content.body
    else -> null
}

/** The text of a message, from the SDK's cache or else the server; null when it isn't text or can't be read. */
internal suspend fun messageText(client: Client, roomId: String, eventId: String): String? = withContext(Dispatchers.Default) {
    try {
        client.getRoom(roomId)?.use { room ->
            room.loadOrFetchEvent(eventId).use { event ->
                ((event.content() as? TimelineEventContent.MessageLike)?.content as? MessageLikeEventContent.RoomMessage)?.let(::text)
            }
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }
}
