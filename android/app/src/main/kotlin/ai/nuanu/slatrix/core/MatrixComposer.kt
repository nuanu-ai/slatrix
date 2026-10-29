package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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
class MatrixComposer(scope: CoroutineScope, private val room: Room, private val sendMessage: suspend (ComposerMessage) -> Boolean) {
    private val lifetime = SupervisorJob(scope.coroutineContext[Job])
    private val operations = CoroutineScope(scope.coroutineContext + lifetime)
    private val mutableState = MutableStateFlow(ComposerState())
    val state: StateFlow<ComposerState> = mutableState.asStateFlow()
    private val edits = Channel<Unit>(Channel.CONFLATED)
    private val draftLock = Mutex()
    private var loaded = false
    private var failure: Failure? = null
    private var revision = 0L
    private var savedRevision = 0L
    private val worker = operations.launch {
        try {
            restore()
            for (edit in edits) if (loaded) flush() else restore()
        } finally {
            withContext(NonCancellable) { flush() }
            edits.close()
        }
    }

    fun edit(text: String) {
        if (!loaded || !worker.isActive || text == mutableState.value.text) return
        revision++
        mutableState.value = mutableState.value.copy(text = text)
        edits.trySend(Unit)
    }

    fun send() {
        val current = mutableState.value
        if (!loaded || !lifetime.isActive || current.sending) return
        val message = ComposerFormat.message(ComposerFormat.plainTextDraft(current.text))
        if (message.body.isBlank()) return
        val sendingRevision = revision
        failure = null
        mutableState.value = current.copy(sending = true, error = null)
        operations.launch {
            try {
                val accepted = sendMessage(message)
                currentCoroutineContext().ensureActive()
                if (accepted) {
                    if (revision == sendingRevision) {
                        revision++
                        mutableState.value = mutableState.value.copy(text = "")
                        edits.trySend(Unit)
                    }
                } else fail(Failure.Send)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                fail(Failure.Send)
            } finally {
                if (lifetime.isActive) mutableState.value = mutableState.value.copy(sending = false)
            }
        }
    }

    fun retry() {
        if (!lifetime.isActive) return
        if (failure == Failure.Send) send()
        else {
            if (!loaded) mutableState.value = mutableState.value.copy(loading = true)
            edits.trySend(Unit)
        }
    }

    suspend fun close() { withContext(NonCancellable) { lifetime.cancelAndJoin() } }

    suspend fun flush(): Boolean = draftLock.withLock {
        do {
            if (!persist()) return@withLock false
        } while (revision != savedRevision)
        true
    }

    private suspend fun restore() = draftLock.withLock {
        try {
            val draft = room.loadComposerDraft(null)
            currentCoroutineContext().ensureActive()
            loaded = true
            failure = null
            mutableState.value = mutableState.value.copy(text = draft?.plainText.orEmpty(), loading = false, error = null)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            currentCoroutineContext().ensureActive()
            fail(Failure.Restore)
            mutableState.value = mutableState.value.copy(loading = false)
        }
    }

    private suspend fun persist(): Boolean {
        if (!loaded) return false
        if (revision == savedRevision) return true
        val savingRevision = revision
        val text = mutableState.value.text
        try {
            if (text.isEmpty()) room.clearComposerDraft(null)
            else room.saveComposerDraft(ComposerDraft(text, null, ComposerDraftType.NewMessage, emptyList()), null)
            savedRevision = savingRevision
            if (failure == Failure.Save) {
                failure = null
                mutableState.value = mutableState.value.copy(error = null)
            }
            return true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            fail(Failure.Save)
            return false
        }
    }

    private fun fail(reason: Failure) {
        failure = reason
        mutableState.value = mutableState.value.copy(error = when (reason) {
            Failure.Restore -> "Couldn’t restore your draft."
            Failure.Save -> "Couldn’t save your draft."
            Failure.Send -> "Couldn’t send your message. Try again."
        })
    }

    private enum class Failure { Restore, Save, Send }
}
