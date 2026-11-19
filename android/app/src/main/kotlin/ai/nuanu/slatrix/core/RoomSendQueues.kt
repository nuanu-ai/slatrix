package ai.nuanu.slatrix.core

import java.util.concurrent.ConcurrentHashMap
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
import org.matrix.rustcomponents.sdk.DateDividerMode
import org.matrix.rustcomponents.sdk.EventOrTransactionId
import org.matrix.rustcomponents.sdk.EventSendState
import org.matrix.rustcomponents.sdk.RoomSendQueueUpdate
import org.matrix.rustcomponents.sdk.SendQueueRoomUpdateListener
import org.matrix.rustcomponents.sdk.SendTarget
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.TimelineConfiguration
import org.matrix.rustcomponents.sdk.TimelineDiff
import org.matrix.rustcomponents.sdk.TimelineFilter
import org.matrix.rustcomponents.sdk.TimelineFocus
import org.matrix.rustcomponents.sdk.TimelineItem
import org.matrix.rustcomponents.sdk.TimelineListener
import org.matrix.rustcomponents.sdk.VirtualTimelineItem
import uniffi.matrix_sdk_ui.TimelineReadReceiptTracking

internal class RoomSendQueues(private val client: Client, private val connection: StateFlow<ConnectionState>,
    private val foreground: StateFlow<Boolean>) {
    private data class Message(val room: String, val transaction: String)
    private sealed interface Change {
        data object Connected : Change
        data object RetryListener : Change
        data class Queued(val message: Message) : Change
        data class Sending(val message: Message, val recoverable: Boolean) : Change
        data class Refused(val message: Message) : Change
        data class Cancelled(val message: Message) : Change
        /** Everything queued before the listener attached has been heard. */
        data object Launched : Change
    }

    private val changes = Channel<Change>(Channel.UNLIMITED)
    private val listener = object : SendQueueRoomUpdateListener {
        override fun onUpdate(roomId: String, update: RoomSendQueueUpdate) {
            try {
                when (update) {
                    is RoomSendQueueUpdate.NewLocalEvent -> changes.trySend(Change.Queued(Message(roomId, update.transactionId)))
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
        // What each room's queue holds, by transaction, and the room's search for a refused change, if one runs.
        val queued = ConcurrentHashMap<String, MutableSet<String>>()
        val sweeps = mutableMapOf<String, Job>()
        fun sweep(room: String) {
            val previous = sweeps[room]
            sweeps[room] = launch {
                previous?.join()
                cancelRefused(room) { queued[room].orEmpty().toSet() }
            }
        }
        try {
            for (change in changes) {
                when (change) {
                    Change.Connected, Change.RetryListener -> {
                        if (!online || change == Change.RetryListener && handle != null) continue
                        if (handle == null) {
                            try {
                                // Attach before waking restored queues, so an immediate failure reaches the listener.
                                withContext(Dispatchers.Default) { handle = client.subscribeToSendQueueUpdates(listener) }
                                changes.send(Change.Launched)
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
                    is Change.Queued -> queued.getOrPut(change.message.room) { ConcurrentHashMap.newKeySet() } += change.message.transaction
                    is Change.Refused -> {
                        pending.remove(change.message)?.job?.cancel()
                        sweep(change.message.room)
                    }
                    Change.Launched -> queued.keys.toList().forEach(::sweep)
                    is Change.Cancelled -> {
                        queued[change.message.room]?.remove(change.message.transaction)
                        val previous = pending.remove(change.message) ?: continue
                        previous.job.cancel()
                        // SDK abort removes the head but leaves a recoverably paused room disabled.
                        resumeRoom(change.message.room)
                    }
                    is Change.Sending -> {
                        if (!change.recoverable) queued[change.message.room]?.remove(change.message.transaction)
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
            sweeps.values.forEach { it.cancel() }
            changes.close()
            withContext(NonCancellable + Dispatchers.Default) { handle?.use { runCatching { it.cancel() } } }
        }
    }

    /**
     * A deletion or edit the server refused stays at the head of its room's send queue, and everything sent there after
     * it waits. As Slack keeps a message it couldn't delete or edit, it's cancelled whichever conversation is open, and
     * goes back to how the server has it. The SDK cancels one only through a timeline that shows its message, so this
     * reads the room, thread replies included, back from the newest message until it finds one, or nothing it hasn't
     * seen is [queued].
     */
    private suspend fun cancelRefused(roomId: String, queued: () -> Set<String>) = withContext(Dispatchers.Default) {
        val room = quietly { client.getRoom(roomId) } ?: return@withContext
        room.use {
            val timeline = quietly {
                room.timelineWithConfiguration(TimelineConfiguration(
                    focus = TimelineFocus.Live(hideThreadedEvents = false), filter = TimelineFilter.All, internalIdPrefix = null,
                    dateDividerMode = DateDividerMode.DAILY, trackReadReceipts = TimelineReadReceiptTracking.DISABLED,
                    reportUtds = false,
                ))
            } ?: return@withContext
            timeline.use {
                val items = mutableListOf<TimelineItem>()
                val updates = Channel<Unit>(Channel.CONFLATED)
                val handle = timeline.addListener(object : TimelineListener {
                    override fun onUpdate(diff: List<TimelineDiff>) {
                        synchronized(items) { diff.forEach { items.applyDiff(it) { item -> item } } }
                        updates.trySend(Unit)
                    }
                })
                try {
                    while (true) {
                        val shown = synchronized(items) { items.toList() }
                        val refused = shown.mapNotNull(::refusedChange)
                        for ((id, target) in refused) quietly { timeline.abortSend(id, target) }
                        // A message the server refused shows in its conversation, which offers to retry or remove it.
                        val echoes = shown.mapNotNullTo(HashSet()) {
                            (it.asEvent()?.eventOrTransactionId as? EventOrTransactionId.TransactionId)?.transactionId
                        }
                        if (refused.isNotEmpty() || echoes.containsAll(queued()) || shown.any(::isStart)) break
                        val reachedStart = quietly { timeline.paginateBackwards(50u) } ?: break
                        // The start of the room shows after every page before it.
                        while (reachedStart && synchronized(items) { items.none(::isStart) }) updates.receive()
                    }
                } finally {
                    runCatching { handle.cancel() }
                    handle.close()
                }
            }
        }
    }

    private fun isStart(item: TimelineItem) = item.asVirtual() is VirtualTimelineItem.TimelineStart
}

/** A deletion or edit of this message the server refused; one the queue retries by itself is still on its way. */
internal fun refusedChange(item: TimelineItem): Pair<EventOrTransactionId, SendTarget>? {
    val event = item.asEvent() ?: return null
    fun refused(state: EventSendState?) = (state as? EventSendState.SendingFailed)?.isRecoverable == false
    val target = when {
        refused(event.redactionSendState) -> SendTarget.Redaction
        refused(event.editSendState) -> SendTarget.Edit
        else -> return null
    }
    return event.eventOrTransactionId to target
}
