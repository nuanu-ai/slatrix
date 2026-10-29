package ai.nuanu.slatrix.core

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
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
}

private class ComposerRoom(var draft: ComposerDraft? = null) : Room(NoHandle) {
    override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? = draft
    override suspend fun saveComposerDraft(draft: ComposerDraft, threadRoot: String?) { this.draft = draft }
    override suspend fun clearComposerDraft(threadRoot: String?) { draft = null }
}
