package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
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
    }

    private val changes = Channel<Change>(Channel.UNLIMITED)
    private val listener = object : SendQueueRoomUpdateListener {
        override fun onUpdate(roomId: String, update: RoomSendQueueUpdate) {
            try {
                when (update) {
                    is RoomSendQueueUpdate.SendError ->
                        changes.trySend(Change.Sending(Message(roomId, update.transactionId), update.isRecoverable))
                    is RoomSendQueueUpdate.SentEvent -> changes.trySend(Change.Sending(Message(roomId, update.transactionId), false))
                    is RoomSendQueueUpdate.CancelledLocalEvent -> changes.trySend(Change.Sending(Message(roomId, update.transactionId), false))
                    else -> Unit
                }
            } finally {
                update.destroy()
            }
        }
    }

    private val online get() = foreground.value && connection.value == ConnectionState.Connected
    fun connected() { changes.trySend(Change.Connected) }

    suspend fun run() = coroutineScope {
        data class Retry(val failures: Int, val job: Job)
        val pending = mutableMapOf<Message, Retry>()
        var handle: TaskHandle? = null
        var retryListener: Job? = null
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
                        }
                    }
                    is Change.Sending -> {
                        val previous = pending.remove(change.message)
                        previous?.job?.cancel()
                        if (!change.recoverable) continue
                        val failures = previous?.failures ?: 0
                        val job = launch {
                            delay(minOf(300_000L, 5_000L shl failures))
                            withContext(Dispatchers.Default) {
                                if (online) runCatching {
                                    client.getRoom(change.message.room)?.use { if (!it.isSendQueueEnabled()) it.enableSendQueue(true) }
                                }
                            }
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
