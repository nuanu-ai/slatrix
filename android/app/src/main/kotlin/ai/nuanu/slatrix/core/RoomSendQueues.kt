package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.RefusedChange
import org.matrix.rustcomponents.sdk.RoomSendQueueUpdate
import org.matrix.rustcomponents.sdk.SendQueueRoomUpdateListener
import org.matrix.rustcomponents.sdk.TaskHandle

internal class RoomSendQueues(private val client: Client, private val connection: StateFlow<ConnectionState>,
    private val foreground: StateFlow<Boolean>) {
    private data class Message(val room: String, val transaction: String)
    private sealed interface Change {
        data object Connected : Change
        data object RetryListener : Change
        data class Sending(val message: Message, val recoverable: Boolean) : Change
        data class Refused(val message: Message) : Change
        data class Cancelled(val message: Message) : Change
    }

    private val changes = Channel<Change>(Channel.UNLIMITED)
    private val mutableUndone = MutableSharedFlow<List<RefusedChange>>(extraBufferCapacity = 16)
    /** What each abort took back out of the queues: refused deletions, edits and reactions. */
    val undone: SharedFlow<List<RefusedChange>> = mutableUndone
    private val listener = object : SendQueueRoomUpdateListener {
        override fun onUpdate(roomId: String, update: RoomSendQueueUpdate) {
            try {
                when (update) {
                    is RoomSendQueueUpdate.SendError -> changes.trySend(Message(roomId, update.transactionId).let {
                        if (update.isRecoverable) Change.Sending(it, true) else Change.Refused(it)
                    })
                    is RoomSendQueueUpdate.SentEvent -> changes.trySend(Change.Sending(Message(roomId, update.transactionId), false))
                    is RoomSendQueueUpdate.CancelledLocalEvent -> changes.trySend(Change.Cancelled(Message(roomId, update.transactionId)))
                    else -> Unit
                }
            } finally {
                update.destroy()
            }
        }
    }

    private val online get() = foreground.value && connection.value == ConnectionState.Connected
    fun connected() { changes.trySend(Change.Connected) }

    private suspend fun resumeRoom(room: String) = withContext(Dispatchers.Default) {
        if (online) runCatching { client.getRoom(room)?.use { if (!it.isSendQueueEnabled()) it.enableSendQueue(true) } }
    }

    suspend fun run() = coroutineScope {
        data class Retry(val failures: Int, val job: Job)
        val pending = mutableMapOf<Message, Retry>()
        var handle: TaskHandle? = null
        var retryListener: Job? = null
        /**
         * A deletion, edit or reaction the server refused stays at the head of its room's send queue, and everything sent
         * there after it waits. As Slack keeps a message it couldn't delete or edit, it's cancelled whichever conversation
         * is open, and goes back to how the server has it.
         */
        fun abortRefused() = launch(Dispatchers.Default) {
            runCatching { client.abortRefusedChanges() }.getOrNull()?.takeIf { it.isNotEmpty() }?.let(mutableUndone::tryEmit)
        }
        // One refused before the app last closed.
        abortRefused()
        try {
            for (change in changes) {
                when (change) {
                    Change.Connected, Change.RetryListener -> {
                        if (!online || change == Change.RetryListener && handle != null) continue
                        if (handle == null) {
                            try {
                                // Attach before waking restored queues, so an immediate failure reaches the listener.
                                withContext(Dispatchers.Default) { handle = client.subscribeToSendQueueUpdates(listener) }
                                retryListener?.cancel()
                            } catch (cancelled: CancellationException) {
                                throw cancelled
                            } catch (_: Exception) {
                                retryListener?.cancel()
                                retryListener = launch { delay(5_000); changes.send(Change.RetryListener) }
                            }
                        }
                        if (online && (change == Change.Connected || handle != null)) {
                            withContext(Dispatchers.Default) { runCatching { client.enableAllSendQueues(true) } }
                            // One refused while the queues were held is heard only now.
                            abortRefused()
                        }
                    }
                    is Change.Refused -> {
                        pending.remove(change.message)?.job?.cancel()
                        abortRefused()
                    }
                    is Change.Cancelled -> {
                        val previous = pending.remove(change.message) ?: continue
                        previous.job.cancel()
                        // SDK abort removes the head but leaves a recoverably paused room disabled.
                        resumeRoom(change.message.room)
                    }
                    is Change.Sending -> {
                        val previous = pending.remove(change.message)
                        previous?.job?.cancel()
                        if (!change.recoverable) continue
                        val failures = previous?.failures ?: 0
                        val job = launch {
                            delay(minOf(300_000L, 5_000L shl failures))
                            resumeRoom(change.message.room)
                        }
                        pending[change.message] = Retry(minOf(failures + 1, 6), job)
                    }
                }
            }
        } finally {
            changes.close()
            withContext(NonCancellable + Dispatchers.Default) { handle?.use { runCatching { it.cancel() } } }
        }
    }
}
