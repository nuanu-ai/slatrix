package ai.nuanu.slatrix.core

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.ProfileDetails
import org.matrix.rustcomponents.sdk.ReceiptThread
import org.matrix.rustcomponents.sdk.ReceiptType
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.ThreadListEntriesListener
import org.matrix.rustcomponents.sdk.ThreadListItemEvent
import org.matrix.rustcomponents.sdk.ThreadListService
import org.matrix.rustcomponents.sdk.ThreadListUpdate
import org.matrix.rustcomponents.sdk.TimelineItemContent
import org.matrix.rustcomponents.sdk.UserReceipt

data class ThreadFeedMessage(val senderName: String, val initials: String, val colorIndex: Int, val body: String, val timestamp: Long,
    val avatarUrl: String? = null)

data class ThreadFeedItem(
    val roomId: String,
    val roomName: String,
    val direct: Boolean,
    val rootId: String,
    val root: ThreadFeedMessage,
    val latest: ThreadFeedMessage?,
    val replies: Int,
    /** Someone else replied after your last read in the thread. */
    val unread: Boolean,
    /** The root's row, for its thread to show at once; null for an event that shows none. */
    val rootRow: ConversationMessage? = null,
) {
    val lastActivity: Long get() = latest?.timestamp ?: root.timestamp
}

data class ThreadFeedState(val items: List<ThreadFeedItem> = emptyList(), val loading: Boolean = true)

/**
 * The threads you're in across [rooms], newest activity first, as the Mac's Threads feed lists them. You're in a thread
 * you started, replied to last, or read. The feed lives as long as [scope], which closes every room's thread list.
 */
class MatrixThreadFeed(scope: CoroutineScope, private val client: Client, private val userId: String, rooms: List<RoomSummary>) {
    private val mutableState = MutableStateFlow(ThreadFeedState(loading = rooms.isNotEmpty()))
    val state: StateFlow<ThreadFeedState> = mutableState.asStateFlow()
    private val roomChannels = ConcurrentHashMap<String, Channel<Unit>>()
    /** Latest reply ID read locally before sync echoes the receipt back; clears on any newer reply. */
    private val locallyRead = ConcurrentHashMap<Pair<String, String>, String>()
    private val latestEventIds = ConcurrentHashMap<Pair<String, String>, String>()

    /** Re-reads receipts for [roomId], or every room when null, since thread list updates don't fire on receipts. */
    fun refresh(roomId: String? = null) {
        if (roomId != null) roomChannels[roomId]?.trySend(Unit)
        else roomChannels.values.forEach { it.trySend(Unit) }
    }

    /** Clears a thread's unread dot as soon as reading [eventId] succeeds, before the receipt echoes back. */
    fun markThreadRead(roomId: String, rootId: String, eventId: String) {
        locallyRead[roomId to rootId] = eventId
        refresh(roomId)
    }

    /** Clears unread dots for every currently listed thread in [roomId] when the room is marked read. */
    fun markRoomRead(roomId: String) {
        for ((key, latestId) in latestEventIds) {
            if (key.first == roomId) locallyRead[key] = latestId
        }
        refresh(roomId)
    }

    init {
        // Thread lists come from the server one room at a time; two at once, as on the Mac.
        val requests = Semaphore(2)
        val updates = Channel<Update>(Channel.UNLIMITED)
        scope.launch(Dispatchers.Default) {
            coroutineScope {
                for (summary in rooms) launch { follow(summary, requests) { items, done -> updates.trySend(Update(summary.id, items, done)) } }
                val byRoom = mutableMapOf<String, List<ThreadFeedItem>>()
                var pending = rooms.size
                for (first in updates) {
                    // Takes every waiting update before sorting, so a busy account's first load sorts once per batch, not per room.
                    var update: Update? = first
                    while (update != null) {
                        update.items?.let { byRoom[update.roomId] = it }
                        if (update.done) pending--
                        update = updates.tryReceive().getOrNull()
                    }
                    mutableState.value = ThreadFeedState(byRoom.values.flatten()
                        .sortedWith(compareByDescending<ThreadFeedItem> { it.lastActivity }.thenBy { it.rootId }), loading = pending > 0)
                }
            }
        }
    }

    /** A room's threads, null when they didn't change, and whether this is the room's first answer. */
    private class Update(val roomId: String, val items: List<ThreadFeedItem>?, val done: Boolean)

    /** Publishes [summary]'s threads after its first page, marked done, and again on every change. */
    private suspend fun follow(summary: RoomSummary, requests: Semaphore, publish: (List<ThreadFeedItem>?, Boolean) -> Unit) {
        var room: Room? = null
        var service: ThreadListService? = null
        var handle: TaskHandle? = null
        var changes: Channel<Unit>? = null
        var counted = false
        try {
            room = client.getRoom(summary.id) ?: return
            val list = room.threadListService().also { service = it }
            val channel = Channel<Unit>(Channel.CONFLATED).also { changes = it }
            roomChannels[summary.id] = channel
            handle = list.subscribeToItemsUpdates(object : ThreadListEntriesListener {
                override fun onUpdate(diff: List<ThreadListUpdate>) { channel.trySend(Unit) }
            })
            runCatching { requests.withPermit { list.paginate() } }.onFailure { if (it is CancellationException) throw it }
            publish(project(summary, room, list), true)
            counted = true
            for (change in channel) publish(project(summary, room, list), false)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // A room whose threads can't load leaves the rest of the feed.
        } finally {
            changes?.let { roomChannels.remove(summary.id, it) }
            handle?.let { runCatching { it.cancel() }; it.close() }
            service?.close()
            room?.close()
            if (!counted) publish(null, true)
        }
    }

    private suspend fun project(summary: RoomSummary, room: Room, list: ThreadListService): List<ThreadFeedItem> {
        val threads = list.items()
        try {
            // An unthreaded room receipt (from Mark as read or another device) marks threads up to its timestamp read too.
            val unthreadedRead = loadReceipt(room, ReceiptThread.Unthreaded)
            return threads.mapNotNull { thread ->
                val latest = thread.latestEvent
                val threadRead = loadReceipt(room, ReceiptThread.Thread(thread.rootEvent.eventId))
                if (!thread.rootEvent.isOwn && latest?.isOwn != true && threadRead == null) return@mapNotNull null
                val key = summary.id to thread.rootEvent.eventId
                if (latest != null) latestEventIds[key] = latest.eventId
                val readLocally = latest != null && locallyRead[key] == latest.eventId
                ThreadFeedItem(summary.id, summary.name, summary.direct, thread.rootEvent.eventId, message(thread.rootEvent),
                    latest?.let(::message), thread.numReplies.toInt(),
                    unread = latest != null && !latest.isOwn && !readLocally &&
                        !threadRead.covers(latest) && !unthreadedRead.covers(latest),
                    rootRow = thread.rootEvent.run {
                        (content as? TimelineItemContent.MsgLike)?.content
                            ?.let { messageRow(eventId, eventId, sender, senderProfile, isOwn, timestamp, it) }
                    })
            }
        } finally {
            threads.forEach { it.destroy() }
        }
    }

    private suspend fun loadReceipt(room: Room, thread: ReceiptThread): UserReceipt? = try {
        room.loadUserReceipt(ReceiptType.READ, thread, userId)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    private fun UserReceipt?.covers(event: ThreadListItemEvent): Boolean =
        this != null && (eventId == event.eventId || (receipt.timestamp ?: 0u) >= event.timestamp)

    private fun message(event: ThreadListItemEvent): ThreadFeedMessage {
        val profile = event.senderProfile as? ProfileDetails.Ready
        val name = event.senderProfile.nameOf(event.sender)
        return ThreadFeedMessage(name, AvatarPlaceholder.initials(name), AvatarPlaceholder.colorIndex(name),
            event.content?.let(::previewText).orEmpty(), event.timestamp.coerceAtMost(Long.MAX_VALUE.toULong()).toLong(),
            profile?.avatarUrl)
    }
}
