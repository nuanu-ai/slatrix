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
import org.matrix.rustcomponents.sdk.Room

data class OpenChannel(
    val room: RoomSummary,
    val conversation: MatrixConversation? = null,
    val composer: MatrixComposer? = null,
    val error: String? = null,
    /** The thread this shows instead of the channel's main timeline. */
    val threadRoot: String? = null,
    /** The message it opens at, highlighted. */
    val at: String? = null,
    /** A thread's root as the channel showed it, so it shows at once. */
    val root: ConversationMessage? = null,
    /** [at] is where its unread messages start, which it opens at without a highlight. */
    val resume: Boolean = false,
    /** Who else is typing here, and telling them you are. */
    val typing: MatrixTyping? = null,
)

private const val RECENT = 4

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
     * The channels left most recently, oldest first, still open with their rooms, so coming back is instant and finds
     * the rows the reader left, as the Mac's RecentTimelines keeps them. With the open one, five: what a reader flips between.
     */
    private val recent = LinkedHashMap<String, Pair<MatrixConversation, Room>>()
    private val worker = scope.launch {
        try {
            for ((token, requested) in requests) {
                if (generation.get() != token) continue
                if (composer?.flush() == false) {
                    if (generation.get() == token) mutableSelected.value = current
                    continue
                }
                if (generation.get() != token) continue
                mutableSelected.value = requested
                release()
                currentCoroutineContext().ensureActive()
                if (requested == null || generation.get() != token) continue
                try {
                    // Kept only while nothing is new: a conversation opened somewhere in particular, or unread, opens fresh,
                    // and one marked unread on its last visit holds its reads back.
                    val kept = recent.remove(requested.room.id)?.let { (conversation, room) ->
                        val state = conversation.state.value
                        if (requested.at == null && requested.threadRoot == null && requested.room.unread == UnreadBadge.None &&
                            !state.focused && state.error == null) conversation to room
                        else { closeKept(conversation); null }
                    }
                    // Held at once, so a failure below closes a kept timeline along with the rest.
                    conversation = kept?.first
                    conversationRoom = kept?.second ?: checkNotNull(client.getRoom(requested.room.id))
                    composerRoom = checkNotNull(client.getRoom(requested.room.id))
                    currentCoroutineContext().ensureActive()
                    val timeline = kept?.first?.also { it.revisit() } ?: MatrixConversation(session, checkNotNull(conversationRoom),
                        requested.threadRoot, requested.at, requested.root, requested.resume)
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
            withContext(NonCancellable) { recent.values.forEach { (conversation) -> closeKept(conversation) } }
            recent.clear()
            mutableSelected.value = null
            requests.close()
        }
    }

    /** Opens [room]; a channel opened without [at] opens where its unread messages start, as on the Mac. */
    fun open(room: RoomSummary, threadRoot: String? = null, at: String? = null, root: ConversationMessage? = null) {
        val resume = room.resumeAt?.takeIf { at == null && threadRoot == null }
        select(OpenChannel(room, threadRoot = threadRoot, at = at ?: resume, root = root, resume = resume != null))
    }

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

    fun back() = select(null)

    private fun select(requested: OpenChannel?) {
        if (!worker.isActive) return
        val token = generation.incrementAndGet()
        if (current == null) mutableSelected.value = requested
        requests.trySend(token to requested)
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
        val channel = current?.takeIf { it.threadRoot == null }?.room?.id
        current = null
        if (left == null || room == null) {
            runCatching { left?.close() }
            // A cancelled constructor task may never enter the conversation's cleanup.
            runCatching { room?.close() }
        } else if (channel != null && !left.state.value.focused && left.state.value.error == null) {
            recent[channel] = left to room
            while (recent.size > RECENT) recent.remove(recent.keys.first())?.let { (conversation) -> closeKept(conversation) }
        } else closeKept(left)
    }

    /** The conversation closes its room, once a thread reply's copy to the channel no longer needs it. */
    private suspend fun closeKept(conversation: MatrixConversation) {
        runCatching { conversation.close() }
    }
}
