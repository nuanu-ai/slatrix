package ai.nuanu.slatrix.core

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.MessageLikeEventContent
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.TimelineEventContent

data class OpenChannel(
    val room: RoomSummary,
    val conversation: MatrixConversation? = null,
    val composer: MatrixComposer? = null,
    val error: String? = null,
    /** The thread this shows instead of the channel's main timeline. */
    val threadRoot: String? = null,
    /** The message it opens at, highlighted. */
    val at: String? = null,
    /** A thread's root as the channel or Threads showed it, so it shows at once. */
    val root: ConversationMessage? = null,
    /** [root] is Threads' row, which the thread's own replaces once it loads. */
    val listedRoot: Boolean = false,
    /** Opened to reply, so the reply field takes the keyboard. */
    val replying: Boolean = false,
    /** [at] is where its unread messages start, which it opens at without a highlight. */
    val resume: Boolean = false,
    /** The reply count the thread's opener showed, such as a Threads item's. */
    val openedWith: Int? = null,
    /** Who else is typing here, and telling them you are. */
    val typing: MatrixTyping? = null,
    /** Last known rows from an earlier visit, shown on frame 0 until the live timeline emits. */
    val cachedRows: List<ConversationRow> = emptyList(),
    /** Account user ID cached alongside [cachedRows] so mentions keep their styling before the live timeline attaches. */
    val cachedOwnUserId: String? = null,
)

/** What shows while the conversation opens: a thread's root or cached snapshot rows from an earlier visit. */
fun OpenChannel.waiting(): ConversationState =
    opening(root, error, openedWith, cachedRows, cachedOwnUserId, listedRoot).copy(hasMore = false)

private const val RECENT = 10
private const val SNAPSHOT_LIMIT = 24
private const val SNAPSHOT_ROWS = 30
private const val THREAD_ROOT_KEY = "thread-root"

class MatrixWorkspace(scope: CoroutineScope, private val client: Client) {
    /** Read once a conversation needs it; the thread workspace shares the main one's. */
    val emojiHistory by lazy { EmojiHistory(scope, client) }
    private val mutableSelected = MutableStateFlow<OpenChannel?>(null)
    val selected: StateFlow<OpenChannel?> = mutableSelected.asStateFlow()
    private val requests = Channel<Pair<Long, OpenChannel?>>(Channel.CONFLATED)
    private val generation = AtomicLong()
    /** Conversations run here, so what they do after closing, such as a thread reply's copy, ends with the workspace. */
    private val sessionJob = SupervisorJob(scope.coroutineContext[Job])
    private val session = CoroutineScope(scope.coroutineContext + sessionJob)
    private var conversationRoom: Room? = null
    private var composerRoom: Room? = null
    private var conversation: MatrixConversation? = null
    private var composer: MatrixComposer? = null
    private var current: OpenChannel? = null
    /**
     * The channels and threads left most recently, oldest first, still open with their rooms, so coming back is instant
     * and finds the rows the reader left, as the Mac's RecentTimelines keeps them. With the open one, eleven each.
     */
    private val recent = LinkedHashMap<String, Pair<MatrixConversation, Room>>()
    private val recentThreads = LinkedHashMap<String, Pair<MatrixConversation, Room>>()
    private data class TimelineSnapshot(val rows: List<ConversationRow>, val ownUserId: String?)
    /** Lightweight last-known rows per room/thread so cold opens never slide in a blank screen. */
    private val snapshots = LinkedHashMap<String, TimelineSnapshot>()
    private val worker = scope.launch {
        try {
            for ((token, requested) in requests) {
                if (generation.get() != token) continue
                if (composer?.flush() == false) {
                    if (generation.get() == token) mutableSelected.value = current
                    continue
                }
                if (generation.get() != token) continue
                if (requested == null) mutableSelected.value = null
                else if (mutableSelected.value?.room?.id != requested.room.id ||
                    mutableSelected.value?.threadRoot != requested.threadRoot) {
                    mutableSelected.value = attachKept(requested)
                }
                release()
                currentCoroutineContext().ensureActive()
                if (requested == null || generation.get() != token) continue
                try {
                    // Kept only while nothing is new: a conversation opened somewhere in particular, or an unread channel,
                    // opens fresh, and one marked unread on its last visit holds its reads back.
                    val cache = cacheFor(requested.threadRoot)
                    val key = cacheKey(requested.room.id, requested.threadRoot)
                    val kept = cache.remove(key)?.let { (conversation, room) ->
                        if (canReuse(requested, conversation)) conversation to room
                        else {
                            saveSnapshot(key, requested.threadRoot != null, conversation)
                            closeKept(conversation)
                            null
                        }
                    }
                    val seeded = if (kept == null) attachSnapshot(requested) else requested
                    if (kept == null && generation.get() == token && mutableSelected.value?.conversation != null) {
                        mutableSelected.value = seeded
                    }
                    // Held at once, so a failure below closes a kept timeline along with the rest.
                    conversation = kept?.first
                    conversationRoom = kept?.second ?: checkNotNull(client.getRoom(requested.room.id))
                    composerRoom = checkNotNull(client.getRoom(requested.room.id))
                    currentCoroutineContext().ensureActive()
                    val timeline = kept?.first?.also { it.revisit(requested.root, requested.openedWith, requested.listedRoot) }
                        ?: MatrixConversation(session, checkNotNull(conversationRoom),
                            requested.threadRoot, requested.at, requested.root, requested.resume, openedWith = requested.openedWith,
                            listedRoot = requested.listedRoot, cachedRows = seeded.cachedRows)
                    conversation = timeline
                    composer = MatrixComposer(scope, checkNotNull(composerRoom), requested.threadRoot, timeline::send)
                    if (generation.get() == token) {
                        current = requested.copy(conversation = timeline, composer = composer,
                            // Matrix typing is room-wide, so a thread keeps out of it, as on the Mac.
                            typing = MatrixTyping(scope, client, requested.room.id).takeIf { requested.threadRoot == null })
                        mutableSelected.value = current
                    } else release()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    release()
                    if (generation.get() == token) {
                        mutableSelected.value = requested.copy(error = "Couldn’t open this conversation.")
                    }
                }
            }
        } finally {
            release()
            withContext(NonCancellable) {
                recent.values.forEach { (conversation) -> closeKept(conversation) }
                recentThreads.values.forEach { (conversation) -> closeKept(conversation) }
            }
            recent.clear()
            recentThreads.clear()
            snapshots.clear()
            mutableSelected.value = null
            requests.close()
        }
    }

    /** Opens [room]; a channel opened without [at] opens where its unread messages start, as on the Mac. */
    fun open(room: RoomSummary, threadRoot: String? = null, at: String? = null, root: ConversationMessage? = null,
        openedWith: Int? = null, listedRoot: Boolean = false, replying: Boolean = false) {
        val resume = room.resumeAt?.takeIf { at == null && threadRoot == null }
        select(OpenChannel(room, threadRoot = threadRoot, at = at ?: resume, root = root, listedRoot = listedRoot,
            resume = resume != null, openedWith = openedWith, replying = replying))
    }

    /** Opens a thread from its Threads [thread] item. */
    fun open(room: RoomSummary, thread: ThreadFeedItem) =
        open(room, thread.rootId, root = thread.rootRow, openedWith = thread.replies, listedRoot = true)

    /** Opens [open] again, as it was asked for, after it failed to. */
    fun retry(open: OpenChannel) =
        open(open.room, open.threadRoot, open.at.takeUnless { open.resume }, open.root, open.openedWith, open.listedRoot, open.replying)

    /**
     * Opens [room] at [eventId], highlighted; a reply in the thread [threadRoot] opens the channel at the root, for the
     * thread to open over it at the reply, as on the Mac.
     */
    fun jumpTo(room: RoomSummary, eventId: String, threadRoot: String?) = open(room, at = threadRoot ?: eventId)

    /** The thread [eventId] replies in, for a caller that doesn't know, such as a search result; it may ask the server. */
    suspend fun threadRootOf(roomId: String, eventId: String): String? = withContext(Dispatchers.Default) {
        try {
            client.getRoom(roomId)?.use { room -> room.loadOrFetchEvent(eventId).use { it.threadRootEventId() } }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // Unknown, it opens where the message is; the live timeline then simply doesn't hold a reply.
            null
        }
    }

    /** Resolves a notification's [eventId] to its message (following reactions) and thread root, if any. */
    suspend fun notificationTargetOf(roomId: String, eventId: String): Pair<String, String?> = withContext(Dispatchers.Default) {
        try {
            client.getRoom(roomId)?.use { room ->
                val (targetId, root) = room.loadOrFetchEvent(eventId).use { event ->
                    val related = ((runCatching { event.content() }.getOrNull() as? TimelineEventContent.MessageLike)
                        ?.content as? MessageLikeEventContent.ReactionContent)?.relatedEventId
                    if (related != null) related to null else eventId to event.threadRootEventId()
                }
                if (targetId != eventId) {
                    targetId to quietly { room.loadOrFetchEvent(targetId).use { it.threadRootEventId() } }
                } else targetId to root
            } ?: (eventId to null)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            eventId to null
        }
    }

    fun back() = select(null)

    private fun select(requested: OpenChannel?) {
        if (!worker.isActive) return
        // A jump to a message the open channel shows stays in it, as on the Mac, once nothing else is on its way; the
        // worker runs on this thread too, so what it published can't change underneath.
        val here = current
        if (requested?.at != null && !requested.resume && requested.threadRoot == null && here != null &&
            mutableSelected.value === here && here.threadRoot == null && here.room.id == requested.room.id &&
            here.conversation?.show(requested.at) == true) return
        val token = generation.incrementAndGet()
        // Shown at once, with any kept timeline already attached so warm channels and threads never flash blank.
        mutableSelected.value = requested?.let(::attachKept)
        requests.trySend(token to requested)
    }

    private fun cacheFor(threadRoot: String?) = if (threadRoot == null) recent else recentThreads

    private fun cacheKey(roomId: String, threadRoot: String?) = threadRoot?.let { "$roomId $it" } ?: roomId

    private fun canReuse(requested: OpenChannel, conversation: MatrixConversation): Boolean {
        if (requested.at != null || !conversation.canKeep) return false
        return requested.threadRoot != null || requested.room.unread == UnreadBadge.None
    }

    private fun attachSnapshot(requested: OpenChannel): OpenChannel {
        if (requested.at != null && !requested.resume) return requested
        val key = cacheKey(requested.room.id, requested.threadRoot)
        val keptState = cacheFor(requested.threadRoot)[key]?.first?.state?.value
        val snapshot = keptState?.takeIf { !it.loading && !it.preview && !it.focused && it.rows.isNotEmpty() }
            ?.let { TimelineSnapshot(snapshotRows(it.rows, requested.threadRoot != null), it.ownUserId) }
            ?: snapshots[key]
            ?: return requested
        return requested.copy(cachedRows = snapshot.rows, cachedOwnUserId = snapshot.ownUserId)
    }

    private fun attachKept(requested: OpenChannel): OpenChannel {
        val kept = cacheFor(requested.threadRoot)[cacheKey(requested.room.id, requested.threadRoot)]?.first
            ?.takeIf { canReuse(requested, it) }
        return if (kept != null) requested.copy(conversation = kept) else attachSnapshot(requested)
    }

    private fun snapshotRows(rows: List<ConversationRow>, isThread: Boolean): List<ConversationRow> {
        if (rows.size <= SNAPSHOT_ROWS) return rows
        if (isThread && rows.firstOrNull()?.id == THREAD_ROOT_KEY) {
            return listOf(rows.first()) + rows.takeLast(SNAPSHOT_ROWS - 1)
        }
        return rows.takeLast(SNAPSHOT_ROWS)
    }

    private fun saveSnapshot(key: String, isThread: Boolean, conversation: MatrixConversation) {
        val state = conversation.state.value
        if (state.loading || state.preview || state.focused || state.rows.isEmpty()) return
        snapshots.remove(key)
        snapshots[key] = TimelineSnapshot(snapshotRows(state.rows, isThread), state.ownUserId)
        while (snapshots.size > SNAPSHOT_LIMIT) {
            val oldest = snapshots.keys.firstOrNull() ?: break
            snapshots.remove(oldest)
        }
    }

    suspend fun close() = withContext(NonCancellable) {
        generation.incrementAndGet()
        mutableSelected.value = null
        worker.cancelAndJoin()
        sessionJob.cancelAndJoin()
    }

    private suspend fun release() = withContext(NonCancellable) {
        // Leaving says you stopped typing, as on the Mac.
        current?.typing?.stopped()
        runCatching { composer?.close() }
        composer = null
        runCatching { composerRoom?.close() }
        composerRoom = null
        val left = conversation
        val room = conversationRoom
        conversation = null
        conversationRoom = null
        val open = current
        current = null
        if (left != null && open != null) {
            saveSnapshot(cacheKey(open.room.id, open.threadRoot), open.threadRoot != null, left)
        }
        if (left == null || room == null) {
            runCatching { left?.close() }
            // A cancelled constructor task may never enter the conversation's cleanup.
            runCatching { room?.close() }
        } else if (open != null && left.canKeep) {
            left.clearVisit()
            val cache = cacheFor(open.threadRoot)
            cache[cacheKey(open.room.id, open.threadRoot)] = left to room
            val active = mutableSelected.value?.takeIf { (it.threadRoot == null) == (open.threadRoot == null) }
                ?.let { cacheKey(it.room.id, it.threadRoot) }
            val limit = if (active != null && active in cache) RECENT + 1 else RECENT
            while (cache.size > limit) {
                val victim = cache.keys.firstOrNull { it != active } ?: break
                cache.remove(victim)?.let { (conversation) ->
                    saveSnapshot(victim, open.threadRoot != null, conversation)
                    closeKept(conversation)
                }
            }
        } else closeKept(left)
    }

    /** The conversation closes its room, once a thread reply's copy to the channel no longer needs it. */
    private suspend fun closeKept(conversation: MatrixConversation) {
        runCatching { conversation.close() }
    }
}
