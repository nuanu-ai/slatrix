package ai.nuanu.slatrix.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.matrix.rustcomponents.sdk.Room

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
    val state: StateFlow<ConversationState> = MutableStateFlow(ConversationState())
    fun loadOlder() = Unit
    suspend fun markRead(eventId: String): Boolean = false
    suspend fun close() = Unit
}
