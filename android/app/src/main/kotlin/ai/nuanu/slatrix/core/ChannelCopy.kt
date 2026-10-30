package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import org.matrix.rustcomponents.sdk.EventOrTransactionId
import org.matrix.rustcomponents.sdk.MsgLikeKind
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.Timeline
import org.matrix.rustcomponents.sdk.TimelineDiff
import org.matrix.rustcomponents.sdk.TimelineItem
import org.matrix.rustcomponents.sdk.TimelineItemContent
import org.matrix.rustcomponents.sdk.TimelineListener

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
 * Waits for the reader's message with [body] to show up in a timeline and reach the server, for its event ID: the copy
 * needs it, and the send queue hands out none. Its listener keeps reading the timeline until it [cancel]s.
 *
 * shortcut: the wait lives in memory, so a reply still queued when the app quits reaches its thread without its copy;
 * keep pending copies with the drafts if that turns out to matter.
 */
internal class SentEcho private constructor(private val body: String) : TimelineListener {
    /** The message's event ID once sent, or null if it never will be. */
    val sent = CompletableDeferred<String?>()
    private class Seen(val id: String, val match: Boolean, val eventId: String?)
    private val items = mutableListOf<Seen>()
    private var before: Set<String>? = null
    private var echo: String? = null
    private var handle: TaskHandle? = null

    @Synchronized override fun onUpdate(diff: List<TimelineDiff>) {
        if (sent.isCompleted) return
        diff.forEach { items.applyDiff(it, ::seen) }
        // The listener's first update is the timeline as it was before the send.
        val before = before ?: return run { before = items.mapTo(HashSet()) { it.id } }
        // Its local echo, or the sent event when both arrive in one update.
        val echo = echo ?: items.firstOrNull { it.match && it.id !in before }?.id?.also { echo = it } ?: return
        // Gone means its sending was cancelled.
        val item = items.firstOrNull { it.id == echo } ?: return finish(null)
        item.eventId?.let(::finish)
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

    private fun seen(item: TimelineItem): Seen {
        val event = item.asEvent()
        val message = ((event?.content as? TimelineItemContent.MsgLike)?.content?.kind as? MsgLikeKind.Message)?.content
        return Seen(item.uniqueId().id, event?.isOwn == true && message?.body == body,
            (event?.eventOrTransactionId as? EventOrTransactionId.EventId)?.eventId)
    }

    companion object {
        /** Starts watching before the message is sent, so a message already there is never taken for it. */
        suspend fun watch(timeline: Timeline, body: String): SentEcho {
            val echo = SentEcho(body)
            echo.listening(timeline.addListener(echo))
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
