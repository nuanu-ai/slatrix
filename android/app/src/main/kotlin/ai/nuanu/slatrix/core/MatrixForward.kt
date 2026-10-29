package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.Membership
import org.matrix.rustcomponents.sdk.Mentions
import org.matrix.rustcomponents.sdk.MessageType
import uniffi.matrix_sdk_base.EncryptionState
import uniffi.ruma_events.MessageLikeEventType

/** Sends a copy of a message to another conversation, with the Mac's checks. */
class MatrixForward(private val client: Client) {
    /** Queues a copy of [content] from [fromRoomId] in [toRoomId]; null once queued, else why it can't go. */
    suspend fun forward(content: MessageType, fromRoomId: String, toRoomId: String): String? = withContext(Dispatchers.Default) {
        try {
            val destination = client.getRoom(toRoomId)?.takeIf { it.membership() == Membership.JOINED }
                ?: return@withContext "Choose a conversation you’ve joined."
            destination.use { room ->
                // An encrypted message must never reach a server in plaintext, attachment keys included.
                if (room.latestEncryptionState() != EncryptionState.ENCRYPTED &&
                    client.getRoom(fromRoomId)?.use { it.latestEncryptionState() } != EncryptionState.NOT_ENCRYPTED) {
                    return@withContext "Choose an encrypted conversation for a message from an encrypted one."
                }
                if (!room.getPowerLevels().use { it.canOwnUserSendMessage(MessageLikeEventType.RoomMessage) }) {
                    return@withContext "You can’t post in that conversation. Choose another."
                }
                room.timeline().use { timeline ->
                    val copy = checkNotNull(timeline.createMessageContent(content))
                    // An empty m.mentions, so the copy pings no one the original named, as on the Mac.
                    copy.use { it.withMentions(Mentions(emptyList(), false)).use { outgoing -> timeline.send(outgoing).close() } }
                }
            }
            null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            "Couldn’t forward this message."
        }
    }
}
