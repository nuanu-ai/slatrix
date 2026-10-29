package ai.nuanu.slatrix.core

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
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
)

class MatrixWorkspace(scope: CoroutineScope, client: Client) {
    /** Read once a conversation needs it; the thread workspace shares the main one's. */
    val emojiHistory by lazy { EmojiHistory(scope, client) }
    private val mutableSelected = MutableStateFlow<OpenChannel?>(null)
    val selected: StateFlow<OpenChannel?> = mutableSelected.asStateFlow()
    private val requests = Channel<Pair<Long, OpenChannel?>>(Channel.CONFLATED)
    private val generation = AtomicLong()
    private var conversationRoom: Room? = null
    private var composerRoom: Room? = null
    private var conversation: MatrixConversation? = null
    private var composer: MatrixComposer? = null
    private var current: OpenChannel? = null
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
                    conversationRoom = checkNotNull(client.getRoom(requested.room.id))
                    composerRoom = checkNotNull(client.getRoom(requested.room.id))
                    currentCoroutineContext().ensureActive()
                    val timeline = MatrixConversation(scope, checkNotNull(conversationRoom), requested.threadRoot)
                    conversation = timeline
                    composer = MatrixComposer(scope, checkNotNull(composerRoom), requested.threadRoot, timeline::send)
                    if (generation.get() == token) {
                        current = requested.copy(conversation = timeline, composer = composer)
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
            mutableSelected.value = null
            requests.close()
        }
    }

    fun open(room: RoomSummary, threadRoot: String? = null) = select(OpenChannel(room, threadRoot = threadRoot))

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
    }

    private suspend fun release() = withContext(NonCancellable) {
        runCatching { composer?.close() }
        composer = null
        runCatching { composerRoom?.close() }
        composerRoom = null
        runCatching { conversation?.close() }
        conversation = null
        // A cancelled constructor task may never enter the conversation's cleanup.
        runCatching { conversationRoom?.close() }
        conversationRoom = null
        current = null
    }
}
