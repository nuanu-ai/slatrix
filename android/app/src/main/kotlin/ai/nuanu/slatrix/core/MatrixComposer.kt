package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.ComposerDraft
import org.matrix.rustcomponents.sdk.ComposerDraftType
import org.matrix.rustcomponents.sdk.Room

data class ComposerState(
    val text: String = "",
    val loading: Boolean = true,
    val sending: Boolean = false,
    val error: String? = null,
)

/** Borrows [room]; the caller closes it after [close] flushes the draft. */
class MatrixComposer(scope: CoroutineScope, private val room: Room, sendMessage: suspend (ComposerMessage) -> Boolean) {
    private val mutableState = MutableStateFlow(ComposerState())
    val state: StateFlow<ComposerState> = mutableState.asStateFlow()
    private val edits = Channel<Unit>(Channel.CONFLATED)
    private var loaded = false
    private var revision = 0L
    private var savedRevision = 0L
    private val worker = scope.launch {
        try {
            try {
                val draft = room.loadComposerDraft(null)
                mutableState.value = mutableState.value.copy(text = draft?.plainText.orEmpty(), loading = false)
                loaded = true
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                mutableState.value = mutableState.value.copy(loading = false, error = "Couldn’t restore your draft.")
            }
            for (edit in edits) persist()
        } finally {
            withContext(NonCancellable) { persist() }
            edits.close()
        }
    }

    fun edit(text: String) {
        if (!loaded || !worker.isActive || text == mutableState.value.text) return
        revision++
        mutableState.value = mutableState.value.copy(text = text)
        edits.trySend(Unit)
    }

    fun send() = Unit
    fun retry() = Unit
    suspend fun close() { worker.cancelAndJoin() }

    private suspend fun persist() {
        if (!loaded || revision == savedRevision) return
        val savingRevision = revision
        val text = mutableState.value.text
        try {
            if (text.isEmpty()) room.clearComposerDraft(null)
            else room.saveComposerDraft(ComposerDraft(text, null, ComposerDraftType.NewMessage, emptyList()), null)
            savedRevision = savingRevision
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            mutableState.value = mutableState.value.copy(error = "Couldn’t save your draft.")
        }
    }
}
