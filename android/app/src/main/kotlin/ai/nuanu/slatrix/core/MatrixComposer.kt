package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withTimeoutOrNull
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
import org.matrix.rustcomponents.sdk.MembershipState
import org.matrix.rustcomponents.sdk.Room

data class ComposerState(
    val text: String = "",
    val loading: Boolean = true,
    val sending: Boolean = false,
    val error: String? = null,
    val target: ComposerTarget? = null,
    val mentions: List<ComposerMention> = emptyList(),
)

private const val SAVE_DELAY_MILLIS = 500L

/** Borrows [room]; the caller closes it after [close] flushes the draft. A thread's draft is kept apart under its [threadRoot]. */
class MatrixComposer(scope: CoroutineScope, private val room: Room, private val threadRoot: String? = null,
    private val sendMessage: suspend (ComposerMessage) -> Boolean) {
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
    /** The draft set aside while you edit a sent message; the store keeps it, never the edit. */
    private var setAside: ComposerState? = null
    private val mutablePeople = MutableStateFlow<MentionPeople?>(null)
    /** Who an @ can name here, once [loadPeople] has read the room's members. */
    val people: StateFlow<MentionPeople?> = mutablePeople.asStateFlow()
    private var peopleLoading: Job? = null
    private val worker = operations.launch {
        try {
            restore()
            // Typing saves once it pauses rather than on every keystroke; leaving flushes the rest.
            for (edit in edits) if (loaded) {
                while (withTimeoutOrNull(SAVE_DELAY_MILLIS) { edits.receive() } != null) Unit
                flush()
            } else restore()
        } finally {
            withContext(NonCancellable) { flush() }
            edits.close()
        }
    }

    fun edit(text: String) {
        val current = mutableState.value
        if (!loaded || !worker.isActive || text == current.text) return
        change(current.copy(text = text, mentions = current.mentions.after(current.text, text)))
    }

    /** Replaces the @ query `start until end` with a pill for [candidate], and a space after it. */
    fun mention(start: Int, end: Int, candidate: MentionCandidate) {
        val current = mutableState.value
        if (!loaded || !worker.isActive || start < 0 || end > current.text.length || start > end) return
        val label = when (candidate) {
            is MentionCandidate.Member -> "@${candidate.person.name}"
            MentionCandidate.Room -> "@room"
        }
        val text = current.text.replaceRange(start, end, "$label ")
        val pill = (candidate as? MentionCandidate.Member)?.let { ComposerMention(start, start + label.length, it.person.id) }
        change(current.copy(text = text, mentions = (current.mentions.after(current.text, text) + listOfNotNull(pill)).sortedBy { it.start }))
    }

    fun loadPeople() {
        if (peopleLoading != null || !lifetime.isActive) return
        peopleLoading = operations.launch {
            mutablePeople.value = quietly {
                val members = mutableListOf<MentionPerson>()
                room.members().use { iterator ->
                    while (true) {
                        val chunk = iterator.nextChunk(500u) ?: break
                        chunk.mapTo(members) { member ->
                            MentionPerson(member.userId, member.displayName?.takeIf { it.isNotBlank() }
                                ?: member.userId.removePrefix("@").substringBefore(':'), when (member.membership) {
                                MembershipState.Join -> "join"
                                MembershipState.Invite -> "invite"
                                else -> "other"
                            })
                        }
                    }
                }
                MentionPeople(members, room.getPowerLevels().use { it.canUserTriggerRoomNotification(room.ownUserId()) })
            }
            // A failed load is asked for again by the next @.
            if (mutablePeople.value == null) peopleLoading = null
        }
    }

    private fun change(next: ComposerState) {
        mutableState.value = next
        if (setAside != null) return
        revision++
        edits.trySend(Unit)
    }

    fun reply(target: ComposerTarget.Reply) {
        if (!loaded || mutableState.value.sending) return
        cancelTarget()
        mutableState.value = mutableState.value.copy(target = target)
    }

    fun editMessage(target: ComposerTarget.Edit) {
        if (!loaded || mutableState.value.sending) return
        cancelTarget()
        setAside = mutableState.value
        mutableState.value = mutableState.value.copy(text = target.body, target = target, mentions = emptyList())
    }

    /** Closes the reply bar, or leaves editing with the draft back in the composer. */
    fun cancelTarget() {
        if (mutableState.value.sending) return
        val draft = setAside
        setAside = null
        mutableState.value = mutableState.value.copy(text = draft?.text ?: mutableState.value.text,
            mentions = draft?.mentions ?: mutableState.value.mentions, target = null)
    }

    fun send() {
        val current = mutableState.value
        if (!loaded || !lifetime.isActive || current.sending) return
        val message = ComposerFormat.message(ComposerFormat.plainTextDraft(current.text, current.mentions)).copy(target = current.target)
        if (message.body.isBlank()) return
        val sendingRevision = revision
        failure = null
        mutableState.value = current.copy(sending = true, error = null)
        operations.launch {
            try {
                val accepted = sendMessage(message)
                currentCoroutineContext().ensureActive()
                if (accepted && message.target is ComposerTarget.Edit) {
                    mutableState.value = mutableState.value.copy(text = setAside?.text.orEmpty(),
                        mentions = setAside?.mentions.orEmpty(), target = null)
                    setAside = null
                } else if (accepted) {
                    mutableState.value = mutableState.value.copy(target = null)
                    if (revision == sendingRevision) {
                        revision++
                        mutableState.value = mutableState.value.copy(text = "", mentions = emptyList())
                        // At once, so a sent message never comes back as a draft.
                        flush()
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
            val draft = room.loadComposerDraft(threadRoot)
            currentCoroutineContext().ensureActive()
            loaded = true
            failure = null
            val (text, mentions) = draft?.htmlText?.let(ComposerFormat::editable) ?: (draft?.plainText.orEmpty() to emptyList())
            mutableState.value = mutableState.value.copy(text = text, mentions = mentions, loading = false, error = null)
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
        val draft = setAside ?: mutableState.value
        val text = draft.text
        try {
            if (text.isEmpty()) room.clearComposerDraft(threadRoot)
            else room.saveComposerDraft(ComposerDraft(text, draft.mentions.takeIf { it.isNotEmpty() }
                ?.let { ComposerFormat.plainTextDraft(text, it) }, ComposerDraftType.NewMessage, emptyList()), threadRoot)
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
