package ai.nuanu.slatrix.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.matrix.rustcomponents.sdk.Room

data class ComposerState(
    val text: String = "",
    val loading: Boolean = true,
    val sending: Boolean = false,
    val error: String? = null,
)

class MatrixComposer(scope: CoroutineScope, room: Room, sendMessage: suspend (ComposerMessage) -> Boolean) {
    val state: StateFlow<ComposerState> = MutableStateFlow(ComposerState(loading = false))
    fun edit(text: String) = Unit
    fun send() = Unit
    fun retry() = Unit
    suspend fun close() = Unit
}
