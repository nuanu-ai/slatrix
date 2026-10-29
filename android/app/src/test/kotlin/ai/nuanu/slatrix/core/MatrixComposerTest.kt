package ai.nuanu.slatrix.core

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
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
}

private class ComposerRoom(var draft: ComposerDraft? = null) : Room(NoHandle) {
    override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? = draft
    override suspend fun saveComposerDraft(draft: ComposerDraft, threadRoot: String?) { this.draft = draft }
    override suspend fun clearComposerDraft(threadRoot: String?) { draft = null }
}
