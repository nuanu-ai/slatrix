package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import org.matrix.rustcomponents.sdk.EventOrTransactionId
import org.matrix.rustcomponents.sdk.EventSendState
import org.matrix.rustcomponents.sdk.FormattedBody
import org.matrix.rustcomponents.sdk.Mentions
import org.matrix.rustcomponents.sdk.MessageFormat
import org.matrix.rustcomponents.sdk.MessageType
import org.matrix.rustcomponents.sdk.MsgLikeKind
import org.matrix.rustcomponents.sdk.ProfileDetails
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.TextMessageContent
import org.matrix.rustcomponents.sdk.Timeline
import org.matrix.rustcomponents.sdk.TimelineDiff
import org.matrix.rustcomponents.sdk.TimelineItem
import org.matrix.rustcomponents.sdk.TimelineItemContent
import org.matrix.rustcomponents.sdk.TimelineListener

enum class MessageKind { Text, Notice, Emote, Attachment, Encrypted, Deleted, Unsupported }
enum class MessageSendState { Sent, Sending, Failed }

data class ConversationMessage(
    val id: String,
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
)

data class ConversationState(
    val messages: List<ConversationMessage> = emptyList(),
    val loading: Boolean = true,
    val loadingHistory: Boolean = false,
    val hasMore: Boolean = true,
    val error: String? = null,
    val sending: Boolean = false,
    val sendError: String? = null,
)

class MatrixConversation(scope: CoroutineScope, room: Room) {
    private val lifetime = SupervisorJob(scope.coroutineContext[Job])
    private val operations = CoroutineScope(scope.coroutineContext + lifetime)
    private val mutableState = MutableStateFlow(ConversationState())
    val state: StateFlow<ConversationState> = mutableState.asStateFlow()
    private val ready = CompletableDeferred<Timeline>()
    private val updates = Channel<List<TimelineDiff>>(Channel.UNLIMITED)
    private val pageLock = Mutex()
    private val sendLock = Mutex()
    private val items = mutableListOf<ConversationMessage?>()

    init {
        operations.launch {
            var timeline: Timeline? = null
            var listener: TaskHandle? = null
            try {
                timeline = room.timeline()
                currentCoroutineContext().ensureActive()
                listener = timeline.addListener(object : TimelineListener {
                    override fun onUpdate(diff: List<TimelineDiff>) { updates.trySend(diff) }
                })
                currentCoroutineContext().ensureActive()
                ready.complete(timeline)
                mutableState.update { it.copy(loading = false) }
                loadOlder()
                for (batch in updates) {
                    batch.forEach(::apply)
                    mutableState.update { it.copy(messages = items.filterNotNull(), loading = false) }
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
    }

    fun loadOlder() {
        operations.launch {
            if (!pageLock.tryLock()) return@launch
            try {
                if (!mutableState.value.hasMore) return@launch
                mutableState.update { it.copy(loadingHistory = true, error = null) }
                val timeline = ready.await()
                val endReached = timeline.paginateBackwards(50u)
                currentCoroutineContext().ensureActive()
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
                        timeline.send(outgoing).close()
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

    suspend fun markRead(eventId: String): Boolean = false

    suspend fun close() { lifetime.cancelAndJoin() }

    private fun apply(diff: TimelineDiff) {
        when (diff) {
            is TimelineDiff.Append -> items.addAll(diff.values.map(::message))
            is TimelineDiff.Clear -> items.clear()
            is TimelineDiff.PushFront -> items.add(0, message(diff.value))
            is TimelineDiff.PushBack -> items.add(message(diff.value))
            is TimelineDiff.PopFront -> items.removeAt(0)
            is TimelineDiff.PopBack -> items.removeAt(items.lastIndex)
            is TimelineDiff.Insert -> items.add(diff.index.toInt(), message(diff.value))
            is TimelineDiff.Set -> items[diff.index.toInt()] = message(diff.value)
            is TimelineDiff.Remove -> items.removeAt(diff.index.toInt())
            is TimelineDiff.Truncate -> items.subList(diff.length.toInt(), items.size).clear()
            is TimelineDiff.Reset -> { items.clear(); items.addAll(diff.values.map(::message)) }
        }
    }

    private fun message(item: TimelineItem): ConversationMessage? {
        val event = item.asEvent() ?: return null
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
        )
    }
}
