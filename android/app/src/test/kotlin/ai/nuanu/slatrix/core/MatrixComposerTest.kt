package ai.nuanu.slatrix.core

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.ComposerDraft
import org.matrix.rustcomponents.sdk.ComposerDraftType
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.Room

class MatrixComposerTest {
    @Test fun restoresDraftAndFlushesTheLastEditBeforeNavigation() = runTest {
        val room = ComposerRoom(ComposerDraft("Remember this", null, ComposerDraftType.NewMessage, emptyList()))
        val composer = MatrixComposer(backgroundScope, room) { true }
        assertEquals("Remember this", composer.state.first { !it.loading }.text)

        composer.edit("Finish tomorrow\nwith <details>")
        composer.close()
        val reopened = MatrixComposer(backgroundScope, room) { true }
        assertEquals("Finish tomorrow\nwith <details>", reopened.state.first { !it.loading }.text)
        reopened.close()
    }

    @Test fun typingIsSavedAfterAPauseAndSendingClearsTheStoredDraftAtOnce() = runTest {
        val room = ComposerRoom()
        val composer = MatrixComposer(backgroundScope, room) { true }
        composer.state.first { !it.loading }
        composer.edit("H")
        composer.edit("He")
        runCurrent()
        assertNull("Each keystroke must not write the encrypted store", room.draft)
        composer.edit("Hello")
        advanceUntilIdle()
        assertEquals("Hello", room.draft?.plainText)

        composer.send()
        runCurrent()
        assertNull("A sent message must not come back as a draft", room.draft)
        composer.close()
    }

    @Test fun sendFailureKeepsTheDraftAndLaterSuccessPreservesAReeditedDraft() = runTest {
        val room = ComposerRoom()
        val submissions = Channel<ComposerMessage>(Channel.UNLIMITED)
        val results = Channel<Boolean>(Channel.UNLIMITED)
        val composer = MatrixComposer(backgroundScope, room) {
            submissions.send(it)
            results.receive()
        }
        composer.state.first { !it.loading }
        composer.edit("Hi @mira:example.org\n<tomorrow>")
        composer.send()
        runCurrent()
        assertTrue("Sending must remain visible until the SDK accepts the message", composer.state.value.sending)
        val outgoing = submissions.receive()
        assertEquals("Hi @mira\n<tomorrow>", outgoing.body)
        assertEquals(listOf("@mira:example.org"), outgoing.mentions)
        results.send(false)
        composer.state.first { !it.sending }
        assertNotNull(composer.state.value.error)
        assertEquals("Hi @mira:example.org\n<tomorrow>", composer.state.value.text)

        composer.retry()
        submissions.receive()
        composer.edit("A different draft")
        composer.edit("Hi @mira:example.org\n<tomorrow>")
        results.send(true)
        composer.state.first { !it.sending }
        assertEquals("Hi @mira:example.org\n<tomorrow>", composer.state.value.text)
        composer.close()
        val reopened = MatrixComposer(backgroundScope, room) { true }
        assertEquals("Hi @mira:example.org\n<tomorrow>", reopened.state.first { !it.loading }.text)
        reopened.send()
        assertEquals("", reopened.state.first { !it.sending }.text)
        reopened.close()
        val sent = MatrixComposer(backgroundScope, room) { true }
        assertEquals("", sent.state.first { !it.loading }.text)
        sent.close()
    }

    @Test fun storageFailuresRetryWithoutReplacingTheUnrestoredDraftOrSendingIt() = runTest {
        val room = ComposerRoom(ComposerDraft("Stored safely", null, ComposerDraftType.NewMessage, emptyList()))
        room.loadFailure = IllegalStateException("Store unavailable")
        val composer = MatrixComposer(backgroundScope, room) { error("A storage retry must not send") }
        composer.state.first { !it.loading }
        assertNotNull(composer.state.value.error)
        composer.edit("A placeholder must not replace the stored draft")

        room.loadFailure = null
        composer.retry()
        runCurrent()
        assertEquals("Stored safely", composer.state.value.text)
        assertNull(composer.state.value.error)

        room.saveFailure = IllegalStateException("Disk unavailable")
        composer.edit("Keep the pending edit")
        runCurrent()
        assertNotNull(composer.state.value.error)
        assertEquals("Keep the pending edit", composer.state.value.text)
        room.saveFailure = null
        composer.retry()
        runCurrent()
        assertNull(composer.state.value.error)
        composer.close()
        val reopened = MatrixComposer(backgroundScope, room) { true }
        assertEquals("Keep the pending edit", reopened.state.first { !it.loading }.text)
        reopened.close()
    }
}

private class ComposerRoom(var draft: ComposerDraft? = null) : Room(NoHandle) {
    var loadFailure: Exception? = null
    var saveFailure: Exception? = null
    override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? {
        loadFailure?.let { throw it }
        return draft
    }
    override suspend fun saveComposerDraft(draft: ComposerDraft, threadRoot: String?) {
        saveFailure?.let { throw it }
        this.draft = draft
    }
    override suspend fun clearComposerDraft(threadRoot: String?) { draft = null }
}
