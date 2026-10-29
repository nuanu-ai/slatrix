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

/** The room's main timeline, or with [threadRoot] the thread that message starts. */
class MatrixConversation(scope: CoroutineScope, private val room: Room, private val threadRoot: String? = null) {
    private val lifetime = SupervisorJob(scope.coroutineContext[Job])
    private val operations = CoroutineScope(scope.coroutineContext + lifetime)
    private val mutableState = MutableStateFlow(ConversationState())
    val state: StateFlow<ConversationState> = mutableState.asStateFlow()
    private val ready = CompletableDeferred<Timeline>()
    private val updates = Channel<List<TimelineDiff>>(Channel.UNLIMITED)
    private val pageLock = Mutex()
    private val sendLock = Mutex()
    private val readLock = Mutex()
    private var lastRead: String? = null
    private val items = mutableListOf<ConversationRow?>()
    /**
     * Pages asked for since an older message last showed. Joins, topic changes and other hidden events can fill page
     * after page, so history stops loading on its own after a few of those, as on the Mac.
     */
    @Volatile private var blankPages = 0

    private val updating = operations.launch {
        var timeline: Timeline? = null
        var listener: TaskHandle? = null
        try {
            timeline = room.timelineWithConfiguration(TimelineConfiguration(
                focus = threadRoot?.let(TimelineFocus::Thread) ?: TimelineFocus.Live(hideThreadedEvents = true), filter = TimelineFilter.All,
                internalIdPrefix = null, dateDividerMode = DateDividerMode.DAILY,
                trackReadReceipts = TimelineReadReceiptTracking.MESSAGE_LIKE_EVENTS, reportUtds = false,
            ))
            currentCoroutineContext().ensureActive()
            listener = timeline.addListener(object : TimelineListener {
                override fun onUpdate(diff: List<TimelineDiff>) { updates.trySend(diff) }
            })
            currentCoroutineContext().ensureActive()
            // Still loading until the listener's first batch, the cached items, is published.
            ready.complete(timeline)
            var oldest: String? = null
            for (batch in updates) {
                // asEvent blocks on the SDK, so a batch is mapped off the main thread.
                val rows = withContext(Dispatchers.Default) { batch.forEach(::apply); rows() }
                // A cleared or reset timeline starts over from the live end.
                val reset = batch.any { it is TimelineDiff.Clear || it is TimelineDiff.Reset }
                val first = rows.firstOrNull { it is ConversationMessage }?.id
                if (first != oldest) { oldest = first; blankPages = 0 }
                mutableState.update { it.copy(rows = rows, loading = false, hasMore = it.hasMore || reset) }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            currentCoroutineContext().ensureActive()
            ready.completeExceptionally(failure)
            mutableState.update { it.copy(loading = false, error = "Couldn’t load this conversation.") }
        } finally {
            ready.completeExceptionally(CancellationException())
            listener?.let { runCatching { it.cancel() }; it.close() }
            timeline?.close()
            room.close()
            updates.close()
        }
    }

    fun loadOlder() {
        operations.launch {
            if (!pageLock.tryLock()) return@launch
            try {
                if (!mutableState.value.hasMore || blankPages >= MAX_BLANK_PAGES) return@launch
                mutableState.update { it.copy(loadingHistory = true, error = null) }
                val timeline = ready.await()
                val endReached = timeline.paginateBackwards(50u)
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
                val timeline = ready.await()
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
            when (quietly { ready.await().toggleReaction(id, key) }) {
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
            if (quietly { ready.await().redactEvent(id, null) } == null) announce("Couldn’t delete this message.")
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
            runCatching { action(ready.await(), id) }.onFailure { if (it is CancellationException) throw it }
        }
    }

    suspend fun markRead(eventId: String): Boolean {
        if (!lifetime.isActive) return false
        val task = operations.async {
            readLock.withLock {
                try {
                    val timeline = ready.await()
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

    private fun isLatestRemote(eventId: String): Boolean =
        lifetime.isActive && mutableState.value.rows.asReversed().firstNotNullOfOrNull { (it as? ConversationMessage)?.eventId } == eventId

    suspend fun close() { lifetime.cancelAndJoin() }

    private fun apply(diff: TimelineDiff) {
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
    private fun rows(): List<ConversationRow> {
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
            editable = event.isEditable && kind in setOf(MessageKind.Text, MessageKind.Notice, MessageKind.Emote),
        )
    }
}
