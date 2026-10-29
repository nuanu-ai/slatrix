package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.DateDividerMode
import org.matrix.rustcomponents.sdk.EditedContent
import org.matrix.rustcomponents.sdk.EventOrTransactionId
import org.matrix.rustcomponents.sdk.EventSendState
import org.matrix.rustcomponents.sdk.FormattedBody
import org.matrix.rustcomponents.sdk.Mentions
import org.matrix.rustcomponents.sdk.MessageFormat
import org.matrix.rustcomponents.sdk.MessageType
import org.matrix.rustcomponents.sdk.MsgLikeKind
import org.matrix.rustcomponents.sdk.ProfileDetails
import org.matrix.rustcomponents.sdk.QueueWedgeError
import org.matrix.rustcomponents.sdk.ReceiptType
import org.matrix.rustcomponents.sdk.SendTarget
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.TextMessageContent
import org.matrix.rustcomponents.sdk.Timeline
import org.matrix.rustcomponents.sdk.TimelineConfiguration
import org.matrix.rustcomponents.sdk.TimelineDiff
import org.matrix.rustcomponents.sdk.TimelineFilter
import org.matrix.rustcomponents.sdk.TimelineFocus
import org.matrix.rustcomponents.sdk.TimelineItem
import org.matrix.rustcomponents.sdk.TimelineItemContent
import org.matrix.rustcomponents.sdk.TimelineListener
import org.matrix.rustcomponents.sdk.VirtualTimelineItem
import uniffi.matrix_sdk_ui.TimelineEventFocusThreadMode
import uniffi.matrix_sdk_ui.TimelineReadReceiptTracking

enum class MessageKind { Text, Notice, Emote, Attachment, Encrypted, Deleted, Unsupported }
enum class MessageSendState { Sent, Sending, Failed }

sealed interface ConversationRow { val id: String }

data class DayDivider(override val id: String, val timestamp: Long) : ConversationRow

data class ConversationMessage(
    override val id: String,
    val eventId: String?,
    val senderId: String,
    val senderName: String,
    val body: String,
    val formattedBody: String?,
    val timestamp: Long,
    val kind: MessageKind,
    val sendState: MessageSendState,
    val own: Boolean,
    val initials: String,
    val colorIndex: Int,
    /** Follows a message from the same sender, so it shows without avatar and name. */
    val grouped: Boolean = false,
    /** A local echo's, for retrying or deleting it. */
    val transactionId: String? = null,
    /** A failed send someone can retry; a signed-out session can only delete it. */
    val canRetry: Boolean = false,
    /** The failure paused the room's send queue, so retrying resumes the queue, as on the Mac. */
    val queuePaused: Boolean = false,
    /** Your own text message, which you can edit. */
    val editable: Boolean = false,
) : ConversationRow

data class ConversationState(
    val rows: List<ConversationRow> = emptyList(),
    val loading: Boolean = true,
    val loadingHistory: Boolean = false,
    val hasMore: Boolean = true,
    val error: String? = null,
    val sending: Boolean = false,
    val sendError: String? = null,
    /** Says for a moment that an action on a message failed. */
    val notice: String? = null,
    /** The message it opened at, to show and highlight. */
    val highlight: String? = null,
    /** Loaded around an older message rather than live, until the reader reaches the newest and it turns live. */
    val focused: Boolean = false,
)

/** Whether [message] joins [previous] under one avatar and name; the rule's cases are in spec/message-grouping.json. */
fun groupsUnder(previous: ConversationMessage, message: ConversationMessage): Boolean =
    previous.senderId == message.senderId && message.timestamp - previous.timestamp < 5 * 60_000L

private const val MAX_BLANK_PAGES = 5
private const val NOTICE_MILLIS = 4_000L

/** The value, or null when [block] failed; cancellation still cancels. */
internal suspend fun <T> quietly(block: suspend () -> T): T? = try { block() } catch (cancelled: CancellationException) {
    throw cancelled
} catch (_: Exception) { null }

/**
 * The room's main timeline, or with [threadRoot] the thread that message starts. With [at] it opens at that message,
 * highlighted: live when the live timeline holds it, as Slack stays live, else loaded around it until the reader reaches
 * the newest message and it turns live, as on the Mac.
 */
class MatrixConversation(scope: CoroutineScope, private val room: Room, private val threadRoot: String? = null,
    private val at: String? = null) {
    private val lifetime = SupervisorJob(scope.coroutineContext[Job])
    private val operations = CoroutineScope(scope.coroutineContext + lifetime)
    private val mutableState = MutableStateFlow(ConversationState())
    val state: StateFlow<ConversationState> = mutableState.asStateFlow()
    private val ready = CompletableDeferred<Unit>()
    private val updates = Channel<Update>(Channel.UNLIMITED)
    private val pageLock = Mutex()
    private val sendLock = Mutex()
    private val readLock = Mutex()
    private var lastRead: String? = null
    /** The timeline on screen; it and [pending] change only on [operations], which runs on one thread. */
    private var shown: Source? = null
    /** A timeline that replaces [shown] once it holds [pendingAnchor], or with none at its first update. */
    private var pending: Source? = null
    private var pendingAnchor: String? = null
    /** Each timeline numbers its rows from zero, so each gets its own prefix and a swap never reuses a row's key. */
    private var opened = 0
    /**
     * Pages asked for since an older message last showed. Joins, topic changes and other hidden events can fill page
     * after page, so history stops loading on its own after a few of those, as on the Mac.
     */
    @Volatile private var blankPages = 0

    private sealed interface Update {
        data class Batch(val source: Source, val diff: List<TimelineDiff>) : Update
        class CaughtUp(val done: CompletableDeferred<Unit>) : Update
    }

    private inner class Source(val timeline: Timeline, val focused: Boolean) {
        val items = mutableListOf<ConversationRow?>()
        var handle: TaskHandle? = null

        fun holds(eventId: String?) = eventId != null && items.any { (it as? ConversationMessage)?.eventId == eventId }

        fun close() {
            handle?.let { runCatching { it.cancel() }; it.close() }
            timeline.close()
        }
    }

    private val updating = operations.launch {
        try {
            open(threadRoot?.let(TimelineFocus::Thread) ?: TimelineFocus.Live(hideThreadedEvents = true)) { shown = it }
            currentCoroutineContext().ensureActive()
            ready.complete(Unit)
            // A thread shows its reply wherever it is; a channel first checks whether its live timeline holds it.
            var deciding = at != null && threadRoot == null
            var oldest: String? = null
            for (update in updates) {
                if (update is Update.CaughtUp) { update.done.complete(Unit); continue }
                val (source, batch) = update as Update.Batch
                if (source !== shown && source !== pending) continue
                // asEvent blocks on the SDK, so a batch is mapped off the main thread.
                val rows = withContext(Dispatchers.Default) { batch.forEach { source.apply(it) }; source.rows() }
                var swapped = false
                if (source === pending) {
                    if (pendingAnchor != null && !source.holds(pendingAnchor)) continue
                    shown?.close()
                    shown = source
                    pending = null
                    // The timeline taking over may reach back less far, so it may have history to load again.
                    swapped = true
                } else if (deciding) {
                    deciding = false
                    if (!source.holds(at)) try {
                        open(TimelineFocus.Event(checkNotNull(at), 30u, TimelineEventFocusThreadMode.Automatic(true))) {
                            pending = it
                            pendingAnchor = null
                        }
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        // Without the history around it, the conversation still opens, live.
                        pending = null
                    }
                }
                // The live rows wait while the timeline around the message loads, so they never flash.
                if (pending?.focused == true) continue
                // A cleared or reset timeline starts over from the live end.
                val reset = batch.any { it is TimelineDiff.Clear || it is TimelineDiff.Reset }
                val first = rows.firstOrNull { it is ConversationMessage }?.id
                if (first != oldest) { oldest = first; blankPages = 0 }
                mutableState.update {
                    it.copy(rows = rows, loading = false, hasMore = it.hasMore || reset || swapped, focused = source.focused,
                        highlight = it.highlight ?: at?.takeIf { id -> source.holds(id) })
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            currentCoroutineContext().ensureActive()
            ready.completeExceptionally(failure)
            mutableState.update { it.copy(loading = false, error = "Couldn’t load this conversation.") }
        } finally {
            ready.completeExceptionally(CancellationException())
            shown?.close()
            pending?.close()
            room.close()
            updates.close()
        }
    }

    /** [role] places the timeline before it can send its first update, which the SDK may do at once. */
    private suspend fun open(focus: TimelineFocus, role: (Source) -> Unit): Source {
        val timeline = room.timelineWithConfiguration(TimelineConfiguration(
            focus = focus, filter = TimelineFilter.All, internalIdPrefix = "${++opened}-", dateDividerMode = DateDividerMode.DAILY,
            trackReadReceipts = TimelineReadReceiptTracking.MESSAGE_LIKE_EVENTS, reportUtds = false,
        ))
        val source = Source(timeline, focus is TimelineFocus.Event)
        try {
            currentCoroutineContext().ensureActive()
            role(source)
            source.handle = timeline.addListener(object : TimelineListener {
                override fun onUpdate(diff: List<TimelineDiff>) { updates.trySend(Update.Batch(source, diff)) }
            })
            currentCoroutineContext().ensureActive()
        } catch (failure: Throwable) {
            source.close()
            throw failure
        }
        return source
    }

    private suspend fun timeline(): Timeline {
        ready.await()
        return checkNotNull(shown).timeline
    }

    fun loadOlder() {
        operations.launch {
            if (!pageLock.tryLock()) return@launch
            try {
                if (!mutableState.value.hasMore || blankPages >= MAX_BLANK_PAGES) return@launch
                mutableState.update { it.copy(loadingHistory = true, error = null) }
                val endReached = timeline().paginateBackwards(50u)
                currentCoroutineContext().ensureActive()
                // Counted once it went through: a failed request says nothing about what the room holds.
                blankPages++
                mutableState.update { it.copy(hasMore = !endReached) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                mutableState.update { it.copy(error = "Couldn’t load older messages.") }
            } finally {
                if (lifetime.isActive) mutableState.update { it.copy(loadingHistory = false) }
                pageLock.unlock()
            }
        }
    }

    /**
     * For a conversation opened at an older message, once the reader reaches its newest: loads newer messages, and
     * with none left turns live where the reader is, as Slack's does, so new messages arrive and it can be read again.
     * [anchor] is the oldest message on screen, which the live timeline must hold for the screen to stay put.
     */
    fun loadNewer(anchor: String?) {
        operations.launch {
            if (!pageLock.tryLock()) return@launch
            try {
                val focused = shown?.takeIf { it.focused } ?: return@launch
                if (pending != null) return@launch
                if (!focused.timeline.paginateForwards(50u)) return@launch
                currentCoroutineContext().ensureActive()
                goLive(anchor ?: newestEvent())
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // The reader reaching the newest message asks again.
            } finally {
                pageLock.unlock()
            }
        }
    }

    /** Opens the live timeline and shows it once it holds [anchor]; at once, with none. */
    private suspend fun goLive(anchor: String?) {
        var next: Source? = null
        try {
            open(TimelineFocus.Live(hideThreadedEvents = true)) {
                next = it
                pending = it
                pendingAnchor = anchor
            }
            // The reader is at the newest message, so a page or two back reaches the screen unless they're offline.
            var end = false
            for (attempt in 0..3) {
                caughtUp()
                if (pending !== next) return
                if (end || attempt == 3) break
                end = checkNotNull(next).timeline.paginateBackwards(100u)
            }
        } finally {
            // Given up or failed, it stays where it is and the reader reaching the newest message asks again.
            next?.takeIf { pending === it }?.let { pending = null; it.close() }
        }
    }

    /** Waits until every update already sent has been applied, so [pending] says whether the live timeline took over. */
    private suspend fun caughtUp() {
        val done = CompletableDeferred<Unit>()
        updates.send(Update.CaughtUp(done))
        done.await()
    }

    private fun newestEvent(): String? =
        mutableState.value.rows.asReversed().firstNotNullOfOrNull { (it as? ConversationMessage)?.eventId }

    /** False once the timeline failed to open or stopped updating, so only reopening the room can help. */
    fun retry(): Boolean {
        if (!updating.isActive) return false
        loadOlder()
        return true
    }

    suspend fun send(message: ComposerMessage): Boolean {
        if (!lifetime.isActive || message.body.isBlank()) return false
        val task = operations.async {
            if (!sendLock.tryLock()) return@async false
            try {
                mutableState.update { it.copy(sending = true, sendError = null) }
                val timeline = timeline()
                val formatted = message.html?.let { FormattedBody(MessageFormat.Html, it) }
                val content = checkNotNull(timeline.createMessageContent(MessageType.Text(TextMessageContent(message.body, formatted))))
                content.use { raw ->
                    raw.withMentions(Mentions(message.mentions, message.mentionsRoom)).use { outgoing ->
                        when (val target = message.target) {
                            is ComposerTarget.Reply -> timeline.sendReply(outgoing, target.eventId).close()
                            is ComposerTarget.Edit ->
                                timeline.edit(EventOrTransactionId.EventId(target.eventId), EditedContent.RoomMessage(outgoing))
                            null -> timeline.send(outgoing).close()
                        }
                    }
                }
                currentCoroutineContext().ensureActive()
                // A message sent from an older place goes to the present, as sending in Slack takes you there.
                if (shown?.focused == true) operations.launch {
                    pageLock.withLock {
                        try {
                            if (shown?.focused == true && pending == null) goLive(null)
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (_: Exception) {
                            // The message is queued either way; reaching the newest one turns live later.
                        }
                    }
                }
                true
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                mutableState.update { it.copy(sendError = "Couldn’t send your message. Try again.") }
                false
            } finally {
                if (lifetime.isActive) mutableState.update { it.copy(sending = false) }
                sendLock.unlock()
            }
        }
        return try { task.await() } finally { task.cancel() }
    }

    /** Resumes the original send rather than sending again, so a message never goes out twice. */
    fun retrySend(message: ConversationMessage) = unsent(message) { timeline, id ->
        if (message.queuePaused) room.enableSendQueue(true) else timeline.retrySend(id, SendTarget.Event)
    }

    fun deleteUnsent(message: ConversationMessage) = unsent(message) { timeline, id -> timeline.abortSend(id, SendTarget.Event) }

    /** Adds the reaction, or takes back your own, then calls [onAdded] if it added one. */
    fun react(message: ConversationMessage, key: String, onAdded: () -> Unit) {
        val id = EventOrTransactionId.EventId(message.eventId ?: return)
        operations.launch {
            when (quietly { timeline().toggleReaction(id, key) }) {
                true -> onAdded()
                false -> Unit
                null -> announce("Couldn’t update your reaction.")
            }
        }
    }

    fun delete(message: ConversationMessage) {
        val id = EventOrTransactionId.EventId(message.eventId ?: return)
        operations.launch {
            // A failed redaction leaves the message, so its sheet offers Delete again.
            if (quietly { timeline().redactEvent(id, null) } == null) announce("Couldn’t delete this message.")
        }
    }

    suspend fun link(message: ConversationMessage): String? {
        val id = message.eventId ?: return null
        return quietly { room.matrixToEventPermalink(id) }
    }

    private suspend fun announce(notice: String) {
        mutableState.update { it.copy(notice = notice) }
        delay(NOTICE_MILLIS)
        mutableState.update { if (it.notice == notice) it.copy(notice = null) else it }
    }

    private fun unsent(message: ConversationMessage, action: suspend (Timeline, EventOrTransactionId) -> Unit) {
        val id = EventOrTransactionId.TransactionId(message.transactionId ?: return)
        operations.launch {
            // A failed attempt leaves the row failed, so its menu offers the action again.
            runCatching { action(timeline(), id) }.onFailure { if (it is CancellationException) throw it }
        }
    }

    suspend fun markRead(eventId: String): Boolean {
        if (!lifetime.isActive) return false
        val task = operations.async {
            readLock.withLock {
                try {
                    val timeline = timeline()
                    if (!isLatestRemote(eventId)) return@withLock false
                    if (lastRead == eventId) return@withLock true
                    // A thread's timeline sends this for the thread; the channel's marker and unread flag stay.
                    timeline.sendReadReceipt(ReceiptType.READ, eventId)
                    currentCoroutineContext().ensureActive()
                    if (!isLatestRemote(eventId)) return@withLock false
                    if (threadRoot != null) { lastRead = eventId; return@withLock true }
                    timeline.sendReadReceipt(ReceiptType.FULLY_READ, eventId)
                    currentCoroutineContext().ensureActive()
                    if (!isLatestRemote(eventId)) return@withLock false
                    room.setUnreadFlag(false)
                    currentCoroutineContext().ensureActive()
                    if (!isLatestRemote(eventId)) return@withLock false
                    lastRead = eventId
                    true
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    // The next visible message sends it again.
                    false
                }
            }
        }
        return try { task.await() } finally { task.cancel() }
    }

    /** A timeline opened at an older message isn't the newest, so reading it waits until it turns live. */
    private fun isLatestRemote(eventId: String): Boolean =
        lifetime.isActive && shown?.focused != true && newestEvent() == eventId

    suspend fun close() { lifetime.cancelAndJoin() }

    private fun Source.apply(diff: TimelineDiff) {
        when (diff) {
            is TimelineDiff.Append -> items.addAll(diff.values.map(::row))
            is TimelineDiff.Clear -> items.clear()
            is TimelineDiff.PushFront -> items.add(0, row(diff.value))
            is TimelineDiff.PushBack -> items.add(row(diff.value))
            is TimelineDiff.PopFront -> items.removeAt(0)
            is TimelineDiff.PopBack -> items.removeAt(items.lastIndex)
            is TimelineDiff.Insert -> items.add(diff.index.toInt(), row(diff.value))
            is TimelineDiff.Set -> items[diff.index.toInt()] = row(diff.value)
            is TimelineDiff.Remove -> items.removeAt(diff.index.toInt())
            is TimelineDiff.Truncate -> items.subList(diff.length.toInt(), items.size).clear()
            is TimelineDiff.Reset -> { items.clear(); items.addAll(diff.values.map(::row)) }
        }
    }

    /**
     * The visible rows, each message grouped under the one before it when the same sender sent it soon after. A day
     * divider shows only above a message, as on the Mac, since the SDK also starts days that hold only hidden events.
     */
    private fun Source.rows(): List<ConversationRow> {
        val rows = ArrayList<ConversationRow>(items.size)
        var previous: ConversationMessage? = null
        var divider: ConversationRow? = null
        for (index in items.indices) {
            val row = items[index] ?: continue
            if (row !is ConversationMessage) {
                divider = row
                previous = null
                continue
            }
            divider?.let(rows::add)
            divider = null
            val grouped = previous?.let { groupsUnder(it, row) } == true
            // Stored back, so an unchanged row stays the same object in the next batch.
            val current = if (row.grouped == grouped) row else row.copy(grouped = grouped).also { items[index] = it }
            rows.add(current)
            previous = current
        }
        return rows
    }

    private fun row(item: TimelineItem): ConversationRow? {
        val event = item.asEvent() ?: return (item.asVirtual() as? VirtualTimelineItem.DateDivider)?.let {
            DayDivider(item.uniqueId().id, it.ts.coerceAtMost(Long.MAX_VALUE.toULong()).toLong())
        }
        val content = (event.content as? TimelineItemContent.MsgLike)?.content ?: return null
        val senderName = (event.senderProfile as? ProfileDetails.Ready)?.displayName
            ?.takeIf { it.isNotBlank() } ?: event.sender
        var formatted: FormattedBody? = null
        val kind: MessageKind
        val body: String
        when (val value = content.kind) {
            is MsgLikeKind.Message -> {
                body = value.content.body
                kind = when (val type = value.content.msgType) {
                    is MessageType.Text -> { formatted = type.content.formatted; MessageKind.Text }
                    is MessageType.Notice -> { formatted = type.content.formatted; MessageKind.Notice }
                    is MessageType.Emote -> { formatted = type.content.formatted; MessageKind.Emote }
                    is MessageType.Image, is MessageType.Audio, is MessageType.Video,
                    is MessageType.File, is MessageType.Gallery -> MessageKind.Attachment
                    else -> MessageKind.Unsupported
                }
            }
            is MsgLikeKind.UnableToDecrypt -> { body = "Waiting for this message"; kind = MessageKind.Encrypted }
            is MsgLikeKind.Redacted -> { body = "This message was deleted"; kind = MessageKind.Deleted }
            is MsgLikeKind.Sticker -> { body = value.body; kind = MessageKind.Attachment }
            is MsgLikeKind.Poll -> { body = value.question; kind = MessageKind.Unsupported }
            else -> { body = "Unsupported message"; kind = MessageKind.Unsupported }
        }
        val failure = event.localSendState as? EventSendState.SendingFailed
        return ConversationMessage(
            id = item.uniqueId().id,
            eventId = if (event.isRemote) (event.eventOrTransactionId as? EventOrTransactionId.EventId)?.eventId else null,
            senderId = event.sender, senderName = senderName, body = body,
            formattedBody = formatted?.takeIf { it.format is MessageFormat.Html }?.body,
            timestamp = event.timestamp.coerceAtMost(Long.MAX_VALUE.toULong()).toLong(), kind = kind,
            sendState = when (event.localSendState) {
                is EventSendState.NotSentYet -> MessageSendState.Sending
                is EventSendState.SendingFailed -> MessageSendState.Failed
                else -> MessageSendState.Sent
            },
            own = event.isOwn, initials = AvatarPlaceholder.initials(senderName),
            colorIndex = AvatarPlaceholder.colorIndex(senderName),
            transactionId = (event.eventOrTransactionId as? EventOrTransactionId.TransactionId)?.transactionId,
            canRetry = failure != null && failure.error !is QueueWedgeError.ExpiredAccessToken &&
                failure.error !is QueueWedgeError.MissingMediaContent && failure.error !is QueueWedgeError.InvalidMimeType,
            queuePaused = failure?.isRecoverable == true,
            // An edit goes out as text, so only a text message keeps its kind.
            editable = event.isEditable && kind == MessageKind.Text,
        )
    }
}
