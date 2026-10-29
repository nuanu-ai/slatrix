package ai.nuanu.slatrix.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.matrix.rustcomponents.sdk.Client

/** A message the search index matched. */
data class SearchHit(val roomId: String, val eventId: String, val senderId: String, val senderName: String, val body: String,
    val timestamp: Long)

data class MessageSearchState(
    val query: MessageSearchQuery? = null,
    val hits: List<SearchHit> = emptyList(),
    val loading: Boolean = false,
    val endReached: Boolean = true,
    val error: String? = null,
)

class MatrixSearch(scope: CoroutineScope, client: Client) {
    private val mutableState = MutableStateFlow(MessageSearchState())
    val state: StateFlow<MessageSearchState> = mutableState.asStateFlow()

    fun search(query: MessageSearchQuery) = Unit

    fun loadMore() = Unit

    fun clear() = Unit

    suspend fun close() = Unit
}
