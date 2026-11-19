package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.RoomSendQueueUpdate
import org.matrix.rustcomponents.sdk.SendQueueListener
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.TimelineDiff
import org.matrix.rustcomponents.sdk.TimelineItem

/**
 * Slack's "Also send to #channel" for a thread reply: the channel gets a rich reply to it without rel_type m.thread,
 * which MSC3440 lets clients show in the main timeline to advertise a thread message. The rule's cases are in
 * spec/send-to-channel.json.
 */
object ChannelCopy {
    /** The copy's event content as JSON. Its m.mentions is empty, so whoever the reply mentions hears once, from the thread. */
    fun content(message: ComposerMessage, replyTo: String): String = buildString {
        append("""{"msgtype":"m.text","body":""").append(jsonString(message.body))
        message.html?.let { append(""","format":"org.matrix.custom.html","formatted_body":""").append(jsonString(it)) }
        append(""","m.mentions":{},"m.relates_to":{"m.in_reply_to":{"event_id":""").append(jsonString(replyTo)).append("}}}")
    }
}

/**
 * Follows the reader's message through its room's send queue to the server, for its event ID: the copy needs it, and
 * the send hands out only its transaction. It listens from before the send, so one confirmed at once is heard too, until
 * it [cancel]s.
 *
 * shortcut: the wait lives in memory, so a reply still queued when the app quits reaches its thread without its copy;
 * keep pending copies with the drafts if that turns out to matter.
 */
internal class SentEcho private constructor() : SendQueueListener {
    /** The message's event ID once sent, or null if it never will be. */
    val sent = CompletableDeferred<String?>()
    private var transaction: String? = null
    /** What the queue said, by transaction, before the send handed out its own. */
    private val heard = mutableMapOf<String, String?>()
    private var handle: TaskHandle? = null

    @Synchronized override fun onUpdate(update: RoomSendQueueUpdate) {
        try {
            val (id, eventId) = when (update) {
                is RoomSendQueueUpdate.SentEvent -> update.transactionId to update.eventId
                is RoomSendQueueUpdate.CancelledLocalEvent -> update.transactionId to null
                else -> return
            }
            if (transaction == null) heard[id] = eventId else if (id == transaction) finish(eventId)
        } finally {
            update.destroy()
        }
    }

    /** The send's [transaction], as its handle names it. */
    @Synchronized fun follow(transaction: String) {
        this.transaction = transaction
        if (transaction in heard) finish(heard[transaction])
        heard.clear()
    }

    /** For a message that never made it into the send queue, or a session that ended. */
    fun cancel() = finish(null)

    @Synchronized private fun finish(eventId: String?) {
        if (sent.complete(eventId)) handle?.let(::stop)
    }

    @Synchronized private fun listening(handle: TaskHandle) {
        this.handle = handle
        if (sent.isCompleted) stop(handle)
    }

    private fun stop(handle: TaskHandle) {
        runCatching { handle.cancel() }
        handle.close()
    }

    companion object {
        /** Starts listening before the message is sent. */
        suspend fun watch(room: Room): SentEcho {
            val echo = SentEcho()
            echo.listening(room.subscribeToSendQueueUpdates(echo))
            return echo
        }
    }
}

/** Applies [diff] to a timeline's [items], each made by [map]. */
internal fun <T> MutableList<T>.applyDiff(diff: TimelineDiff, map: (TimelineItem) -> T) {
    when (diff) {
        is TimelineDiff.Append -> addAll(diff.values.map(map))
        is TimelineDiff.Clear -> clear()
        is TimelineDiff.PushFront -> add(0, map(diff.value))
        is TimelineDiff.PushBack -> add(map(diff.value))
        is TimelineDiff.PopFront -> removeAt(0)
        is TimelineDiff.PopBack -> removeAt(lastIndex)
        is TimelineDiff.Insert -> add(diff.index.toInt(), map(diff.value))
        is TimelineDiff.Set -> set(diff.index.toInt(), map(diff.value))
        is TimelineDiff.Remove -> removeAt(diff.index.toInt())
        is TimelineDiff.Truncate -> subList(diff.length.toInt(), size).clear()
        is TimelineDiff.Reset -> { clear(); addAll(diff.values.map(map)) }
    }
}

/** [text] as a JSON string literal. */
internal fun jsonString(text: String): String = buildString {
    append('"')
    for (char in text) when {
        char == '"' || char == '\\' -> append('\\').append(char)
        char < ' ' -> append("\\u%04x".format(char.code))
        else -> append(char)
    }
    append('"')
}
