package ai.nuanu.slatrix.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.TypingNotificationsListener

private const val TYPING_PAUSE_MILLIS = 3_000L

/** Who else is typing in a conversation, and telling it when you are, as the Mac does. */
class MatrixTyping(private val scope: CoroutineScope, private val client: Client, private val roomId: String) {
    private val sending = Mutex()
    private var pause: Job? = null

    /** Everyone else typing, by name, while collected. */
    val others: Flow<List<String>> = callbackFlow {
        val room = quietly { client.getRoom(roomId) }
        if (room == null) {
            awaitClose()
            return@callbackFlow
        }
        val ids = Channel<List<String>>(Channel.CONFLATED)
        val handle = room.subscribeToTypingNotifications(object : TypingNotificationsListener {
            override fun call(typingUserIds: List<String>) { ids.trySend(typingUserIds) }
        })
        launch {
            for (typing in ids) send((typing - room.ownUserId()).map { id ->
                quietly { room.memberDisplayName(id) }?.takeIf { it.isNotBlank() } ?: id.removePrefix("@").substringBefore(':')
            })
        }
        awaitClose {
            handle.cancel()
            handle.close()
            room.close()
        }
    }.flowOn(Dispatchers.Default)

    /**
     * Says you're typing while the field holds text, and that you stopped once it pauses for three seconds or empties.
     * The SDK spaces the notices out and drops a stop that follows no start.
     */
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

    /** In order, so a late "typing" never lands after "stopped". */
    private suspend fun say(typing: Boolean) = sending.withLock {
        quietly { client.getRoom(roomId)?.use { it.typingNotice(typing) } }
    }
}
