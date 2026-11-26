package ai.nuanu.slatrix.core

import ai.nuanu.slatrix.push.NotificationText
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
import org.matrix.rustcomponents.sdk.ReceiptThread
import org.matrix.rustcomponents.sdk.ReceiptType
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.UserReceipt
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
    val avatarUrl: String? = null,
)

private const val MAX_ITEMS = 300
private const val LOOKUP_MILLIS = 10_000L

/** The items from [rooms] in workspace [spaceId], as the Mac scopes Activity; a room no longer listed drops out. */
fun List<ActivityItem>.inWorkspace(rooms: List<RoomSummary>, spaceId: String?): List<ActivityItem> {
    val inScope = rooms.filter { WorkspaceMembership.includes(it.direct, it.spaceIds, spaceId) }.mapTo(HashSet()) { it.id }
    return filter { it.roomId in inScope }
}

/**
 * The items as Activity's count holds them: a thread reply stays unread until you open it or a receipt covers it, a
 * mention clears once its conversation has no unread mentions, and anything else clears once its conversation reads.
 */
fun List<ActivityItem>.readWith(rooms: List<RoomSummary>): List<ActivityItem> {
    val byId = rooms.associateBy { it.id }
    return map { item ->
        val room = byId[item.roomId]
        val readByRoom = room != null && when (item.kind) {
            ActivityKind.ThreadReply -> false
            ActivityKind.Mention -> room.mentions == 0L || room.unread == UnreadBadge.None
            else -> room.unread == UnreadBadge.None
        }
        if (item.unread && readByRoom) item.copy(unread = false) else item
    }
}

/**
 * Whether a server read receipt at ([receiptEventId], [receiptTimestampMs]) covers this item. Reactions match by
 * timestamp only because [ActivityItem.eventId] is the reacted message, which may have been read before the reaction.
 */
internal fun ActivityItem.isCoveredByReceipt(receiptEventId: String, receiptTimestampMs: Long?): Boolean {
    if (kind != ActivityKind.Reaction && receiptEventId == eventId) return true
    return receiptTimestampMs != null && receiptTimestampMs >= timestamp
}

/** What a reaction reacted to: its text when readable, and its thread root when it's a thread reply. */
data class ReactedEvent(val text: String?, val threadRoot: String? = null)

/**
 * What the SDK says notified you, newest first, as on the Mac: the events sync and pushes deliver while the app runs.
 * Reactions show when a push rule lets them notify.
 */
class MatrixActivity(private val userId: String, scope: CoroutineScope,
    /** The names a room knows the given members by, for the people a message mentions by ID. */
    private val memberNames: suspend (roomId: String, ids: Set<String>) -> Map<String, String> = { _, _ -> emptyMap() },
    /** The message a reaction reacted to (its text and thread root); null when it can't be read. */
    private val reactedEvent: suspend (roomId: String, eventId: String) -> ReactedEvent?) {
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
            val senderName = DisplayNames.name(sender, notification.senderInfo.displayName, ambiguous = notification.senderInfo.isNameAmbiguous)
            ActivityItem(
                id = "$roomId ${event.eventId()}", roomId = roomId, eventId = reactedTo ?: event.eventId(),
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
                avatarUrl = notification.senderInfo.avatarUrl,
            )
        }.getOrNull() ?: return
        val message = reactedTo
        val mentioned = if (message == null) DisplayNames.mentioned(item.body) else emptySet()
        if (message == null && mentioned.isEmpty()) return add(item)
        // A reaction lands with the message it reacted to, and a mention with the names of who it mentions, so its row
        // doesn't change later; what the server is slow to give lands without it.
        lookups.launch {
            add(if (message != null) {
                val target = withTimeoutOrNull(LOOKUP_MILLIS) { reactedEvent(roomId, message) }
                item.copy(reactedTo = target?.text, threadRoot = target?.threadRoot ?: item.threadRoot)
            } else {
                item.copy(body = DisplayNames.mentions(item.body, withTimeoutOrNull(LOOKUP_MILLIS) { memberNames(roomId, mentioned) }.orEmpty()))
            })
        }
    }

    fun close() = lookups.cancel()

    fun markRead(id: String) = mutableItems.update { current -> current.map { if (it.id == id) it.copy(unread = false) else it } }

    fun markThreadRead(roomId: String, threadRoot: String) = mutableItems.update { current ->
        current.map { if (it.roomId == roomId && it.threadRoot == threadRoot) it.copy(unread = false) else it }
    }

    fun markRoomRead(roomId: String) = mutableItems.update { current ->
        current.map { if (it.roomId == roomId) it.copy(unread = false) else it }
    }

    /** Permanently marks non-thread items in [roomId] read so old mentions don't resurrect on a later mention. */
    fun markRoomMessagesRead(roomId: String) = mutableItems.update { current ->
        current.map { if (it.roomId == roomId && it.kind != ActivityKind.ThreadReply) it.copy(unread = false) else it }
    }

    /** Permanently marks mentions in [roomId] read when the room's mentions drop to zero while other messages remain. */
    fun markRoomMentionsRead(roomId: String) = mutableItems.update { current ->
        current.map { if (it.roomId == roomId && it.kind == ActivityKind.Mention) it.copy(unread = false) else it }
    }

    /**
     * Reconciles unread Activity items (including thread replies and reactions) against the SDK's synced read receipts
     * so messages read on another device clear automatically without manual intervention.
     */
    suspend fun reconcileReceipts(client: Client, roomIds: Set<String>? = null) {
        val pending = mutableItems.value.filter { it.unread && (roomIds == null || it.roomId in roomIds) }
        if (pending.isEmpty()) return
        val byRoom = pending.groupBy { it.roomId }
        val seenIds = withContext(Dispatchers.Default) {
            val covered = HashSet<String>()
            for ((roomId, items) in byRoom) {
                val room = runCatching { client.getRoom(roomId) }.getOrNull() ?: continue
                room.use { openRoom ->
                    val eventTimestamps = HashMap<String, Long?>()
                    suspend fun resolvedTimestamp(receipt: UserReceipt): Long? {
                        if (receipt.eventId in eventTimestamps) return eventTimestamps[receipt.eventId]
                        val ts = (quietly { openRoom.loadOrFetchEvent(receipt.eventId).use { it.timestamp() } }
                            ?: receipt.receipt.timestamp)?.coerceAtMost(Long.MAX_VALUE.toULong())?.toLong()
                        eventTimestamps[receipt.eventId] = ts
                        return ts
                    }
                    suspend fun bestReceipt(thread: ReceiptThread): Pair<String, Long?>? {
                        val pub = loadReceipt(openRoom, ReceiptType.READ, thread)
                        val priv = loadReceipt(openRoom, ReceiptType.READ_PRIVATE, thread)
                        val pubTs = pub?.let { resolvedTimestamp(it) }
                        val privTs = priv?.let { resolvedTimestamp(it) }
                        return when {
                            pub == null && priv == null -> null
                            pub != null && priv == null -> pub.eventId to pubTs
                            pub == null && priv != null -> priv.eventId to privTs
                            else -> if ((privTs ?: 0L) > (pubTs ?: 0L)) priv!!.eventId to privTs else pub!!.eventId to pubTs
                        }
                    }
                    val unthreaded = bestReceipt(ReceiptThread.Unthreaded)
                    val main = if (items.any { it.threadRoot == null }) bestReceipt(ReceiptThread.Main) else null
                    val threads = HashMap<String, Pair<String, Long?>>()
                    for (root in items.mapNotNull { it.threadRoot }.distinct()) {
                        bestReceipt(ReceiptThread.Thread(root))?.let { threads[root] = it }
                    }
                    for (item in items) {
                        val coveredUnthreaded = unthreaded?.let { (id, ts) -> item.isCoveredByReceipt(id, ts) } == true
                        val specific = item.threadRoot?.let { threads[it] } ?: if (item.threadRoot == null) main else null
                        val coveredSpecific = specific?.let { (id, ts) -> item.isCoveredByReceipt(id, ts) } == true
                        if (coveredUnthreaded || coveredSpecific) covered += item.id
                    }
                }
            }
            covered
        }
        if (seenIds.isNotEmpty()) {
            mutableItems.update { current -> current.map { if (it.id in seenIds) it.copy(unread = false) else it } }
        }
    }

    private suspend fun loadReceipt(room: Room, type: ReceiptType, thread: ReceiptThread): UserReceipt? = try {
        room.loadUserReceipt(type, thread, userId)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    private fun add(item: ActivityItem) {
        mutableItems.update { current ->
            // A later decryption of the same event replaces it in place, read if it was.
            val previous = current.firstOrNull { it.id == item.id }
            // A second delivery whose lookup failed keeps the text and thread root the first found.
            (current.filterNot { it.id == item.id } +
                item.copy(unread = previous?.unread ?: item.unread, reactedTo = item.reactedTo ?: previous?.reactedTo,
                    threadRoot = item.threadRoot ?: previous?.threadRoot))
                .sortedWith(compareByDescending<ActivityItem> { it.timestamp }.thenBy { it.id }).take(MAX_ITEMS)
        }
    }
}

/** Sync notifications and fetched events come as sent, so a reply's body still opens with the message it quotes. */
private fun text(content: MessageLikeEventContent.RoomMessage): String? = when (val type = content.messageType) {
    is MessageType.Text -> type.content.body
    is MessageType.Notice -> type.content.body
    is MessageType.Emote -> type.content.body
    else -> null
}?.let { if (content.inReplyToEventId != null) NotificationText.withoutReplyFallback(it) else it }

/** The text and thread root of a reacted message, from the SDK's cache or else the server; null when it can't be read. */
internal suspend fun reactedEvent(client: Client, roomId: String, eventId: String): ReactedEvent? = withContext(Dispatchers.Default) {
    try {
        client.getRoom(roomId)?.use { room ->
            room.loadOrFetchEvent(eventId).use { event ->
                val body = ((event.content() as? TimelineEventContent.MessageLike)?.content as? MessageLikeEventContent.RoomMessage)?.let(::text)
                ReactedEvent(body, event.threadRootEventId())
            }
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }
}
