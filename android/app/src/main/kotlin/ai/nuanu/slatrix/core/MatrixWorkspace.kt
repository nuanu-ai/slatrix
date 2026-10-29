package ai.nuanu.slatrix.core

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
)

class MatrixWorkspace(scope: CoroutineScope, client: Client) {
    private val mutableSelected = MutableStateFlow<OpenChannel?>(null)
    val selected: StateFlow<OpenChannel?> = mutableSelected.asStateFlow()
    private val requests = Channel<OpenChannel?>(Channel.CONFLATED)
    private var conversationRoom: Room? = null
    private var composerRoom: Room? = null
    private var conversation: MatrixConversation? = null
    private var composer: MatrixComposer? = null
    private val worker = scope.launch {
        try {
            for (requested in requests) {
                release()
                currentCoroutineContext().ensureActive()
                if (requested == null || mutableSelected.value !== requested) continue
                try {
                    conversationRoom = checkNotNull(client.getRoom(requested.room.id))
                    composerRoom = checkNotNull(client.getRoom(requested.room.id))
                    currentCoroutineContext().ensureActive()
                    val timeline = MatrixConversation(scope, checkNotNull(conversationRoom))
                    conversation = timeline
                    composer = MatrixComposer(scope, checkNotNull(composerRoom), timeline::send)
                    if (mutableSelected.value === requested) {
                        mutableSelected.value = requested.copy(conversation = timeline, composer = composer)
                    } else release()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    release()
                    if (mutableSelected.value === requested) {
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

    fun open(room: RoomSummary) {
        if (!worker.isActive) return
        val requested = OpenChannel(room)
        mutableSelected.value = requested
        requests.trySend(requested)
    }

    fun back() {
        mutableSelected.value = null
        requests.trySend(null)
    }

    suspend fun close() = withContext(NonCancellable) {
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
    }
}
