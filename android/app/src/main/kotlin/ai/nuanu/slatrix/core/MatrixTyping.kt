package ai.nuanu.slatrix.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.TypingNotificationsListener

private const val TYPING_PAUSE_MILLIS = 3_000L

/** Who else is typing in a conversation, and telling it when you are, as the Mac does. */
class MatrixTyping(private val scope: CoroutineScope, private val client: Client, private val roomId: String) {
    private val sending = Mutex()
    private var said = false
    private var pause: Job? = null

    /** Everyone else typing, by name, while collected. */
    @OptIn(ExperimentalCoroutinesApi::class)
    val others: Flow<List<String>> = callbackFlow {
        val room = client.getRoom(roomId)
        if (room == null) {
            awaitClose()
            return@callbackFlow
        }
        val handle = room.subscribeToTypingNotifications(object : TypingNotificationsListener {
            override fun call(typingUserIds: List<String>) { trySend(typingUserIds - room.ownUserId()) }
        })
        awaitClose {
            handle.cancel()
            handle.close()
            room.close()
        }
    }.mapLatest { ids -> ids.map { name(it) } }.flowOn(Dispatchers.Default)

    /** Says you're typing while the field holds text, and that you stopped once it pauses for three seconds. */
    fun changed(text: String) {
        val typing = text.isNotEmpty()
        pause?.cancel()
        pause = scope.launch {
            say(typing)
            if (typing) {
                delay(TYPING_PAUSE_MILLIS)
                say(false)
            }
        }
    }

    /** Says you stopped, as sending or leaving the conversation does. */
    fun stopped() {
        pause?.cancel()
        pause = scope.launch { say(false) }
    }

    /** In order, so a late "typing" never lands after "stopped"; "stopped" goes only after "typing" did. */
    private suspend fun say(typing: Boolean) = sending.withLock {
        if (!typing && !said) return@withLock
        said = typing
        quietly { client.getRoom(roomId)?.use { it.typingNotice(typing) } }
    }

    private suspend fun name(userId: String): String =
        quietly { client.getRoom(roomId)?.use { it.memberDisplayName(userId) } }?.takeIf { it.isNotBlank() }
            ?: userId.removePrefix("@").substringBefore(':')
}
