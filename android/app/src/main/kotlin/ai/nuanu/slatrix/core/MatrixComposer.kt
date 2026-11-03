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
    val styles: List<ComposerStyle> = emptyList(),
    val typing: ComposerTyping? = null,
    /** A thread's "Also send to #channel", checked for the next reply. */
    val alsoToChannel: Boolean = false,
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
        change(current.copy(text = text, mentions = current.mentions.after(current.text, text),
            styles = ComposerStyles.after(current.styles, current.text, text, current.typing), typing = null))
    }

    /**
     * Turns [kind] on or off over `start until end`, as Slack's toolbar does; a link sets [href] there. At the caret an
     * inline format applies to what is typed next.
     */
    fun format(start: Int, end: Int, kind: ComposerStyle.Kind, href: String? = null) {
        val current = mutableState.value
        if (!loaded || !worker.isActive || start < 0 || end > current.text.length || start > end) return
        val emptyFirstLine = kind.block && start == 0 && ComposerStyles.lineEnd(current.text, 0) == 0
        if (start == end && (!kind.block || emptyFirstLine) && kind != ComposerStyle.Kind.Link) {
            val kinds = ComposerStyles.typing(current.styles, current.typing, current.text, start)
            val toggled = if (kind in kinds) kinds - kind else kinds.filterNot { kind.block && it.block }.toSet() + kind
            mutableState.value = current.copy(typing = ComposerTyping(start, toggled))
            return
        }
        change(current.copy(styles = ComposerStyles.toggled(current.styles, current.text, start, end, kind, href), typing = null))
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
                            }, member.avatarUrl)
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
        val content = target.html?.let(ComposerFormat::editable) ?: ComposerContent(target.body, emptyList())
        mutableState.value = mutableState.value.copy(text = content.text, target = target, mentions = content.mentions,
            styles = content.styles, typing = null)
    }

    /** Closes the reply bar, or leaves editing with the draft back in the composer. */
    fun cancelTarget() {
        if (mutableState.value.sending) return
        val draft = setAside
        setAside = null
        mutableState.value = mutableState.value.copy(text = draft?.text ?: mutableState.value.text,
            mentions = draft?.mentions ?: mutableState.value.mentions, styles = draft?.styles ?: mutableState.value.styles, target = null)
    }

    fun alsoToChannel(checked: Boolean) {
        if (!mutableState.value.sending) mutableState.value = mutableState.value.copy(alsoToChannel = checked)
    }

    fun send() {
        val current = mutableState.value
        if (!loaded || !lifetime.isActive || current.sending) return
        val message = ComposerFormat.message(ComposerFormat.draft(current.text, current.mentions, current.styles))
            .copy(target = current.target, alsoToChannel = current.alsoToChannel)
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
                        mentions = setAside?.mentions.orEmpty(), styles = setAside?.styles.orEmpty(), target = null)
                    setAside = null
                } else if (accepted) {
                    // Slack unchecks "Also send to #channel" once a reply goes.
                    mutableState.value = mutableState.value.copy(target = null, alsoToChannel = false)
                    if (revision == sendingRevision) {
                        revision++
                        mutableState.value = mutableState.value.copy(text = "", mentions = emptyList(), styles = emptyList(), typing = null)
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
            val content = draft?.htmlText?.let(ComposerFormat::editable) ?: ComposerContent(draft?.plainText.orEmpty(), emptyList())
            mutableState.value = mutableState.value.copy(text = content.text, mentions = content.mentions, styles = content.styles,
                loading = false, error = null)
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
            else room.saveComposerDraft(ComposerDraft(text, ComposerFormat.draft(text, draft.mentions, draft.styles)
                .takeIf { draft.mentions.isNotEmpty() || draft.styles.isNotEmpty() }, ComposerDraftType.NewMessage, emptyList()), threadRoot)
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
