package ai.nuanu.slatrix.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.matrix.rustcomponents.sdk.Client

/** The account's recently used emoji, newest first, kept in account data so other devices share the order. */
class EmojiHistory(private val scope: CoroutineScope, private val client: Client) {
    private val mutableState = MutableStateFlow(emptyList<String>())
    val state: StateFlow<List<String>> = mutableState.asStateFlow()

    init {
        scope.launch {
            val stored = quietly { client.getRecentEmojis().map { it.emoji } } ?: return@launch
            // Anything used while the list loaded stays in front of it.
            mutableState.update { used -> used + stored.filter { it !in used } }
        }
    }

    /** Shown at once; losing the account data write only loses the order elsewhere. */
    fun use(emoji: String) {
        mutableState.update { EmojiRecents.adding(emoji, it) }
        scope.launch { quietly { client.addRecentEmoji(emoji) } }
    }
}
