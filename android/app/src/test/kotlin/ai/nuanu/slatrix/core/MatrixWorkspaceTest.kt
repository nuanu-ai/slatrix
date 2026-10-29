package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.matrix.rustcomponents.sdk.*

class MatrixWorkspaceTest {
    @Test fun cancellingTheOwnerFlushesTheDraftBeforeClosingItsRoomAndRejectsQueuedChannels() = runTest {
        val saveStarted = CompletableDeferred<Unit>()
        val allowSave = CompletableDeferred<Unit>()
        val client = WorkspaceClient {
            saveStarted.complete(Unit)
            allowSave.await()
        }
        val owner = Job(backgroundScope.coroutineContext[Job])
        val workspace = MatrixWorkspace(CoroutineScope(backgroundScope.coroutineContext + owner), client)
        val alpha = workspaceRoom("!alpha:example.org", "Alpha")
        workspace.open(alpha)
        runCurrent()
        val composer = requireNotNull(workspace.selected.value?.composer)
        composer.state.first { !it.loading }
        composer.edit("Finish after reopening")
        saveStarted.await()
        workspace.open(workspaceRoom("!beta:example.org", "Beta"))
        runCurrent()
        workspace.open(workspaceRoom("!gamma:example.org", "Gamma"))
        owner.cancel()
        runCurrent()
        allowSave.complete(Unit)
        owner.join()

        assertNull(workspace.selected.value)
        assertEquals(true, client.handles.all { it.uniffiIsDestroyed })
        assertEquals(setOf(alpha.id), client.handles.map { it.id() }.toSet())

        val reopened = MatrixWorkspace(backgroundScope, client)
        reopened.open(alpha)
        runCurrent()
        val restored = requireNotNull(reopened.selected.value?.composer)
        assertEquals("Finish after reopening", restored.state.first { !it.loading }.text)
        reopened.close()
    }

    @Test fun failedDraftSaveKeepsTheChannelOpenUntilTheDraftCanBeSaved() = runTest {
        val saveStarted = CompletableDeferred<Unit>()
        val allowSave = CompletableDeferred<Unit>()
        val client = WorkspaceClient {
            saveStarted.complete(Unit)
            allowSave.await()
        }.also { it.failSaves = true }
        val workspace = MatrixWorkspace(backgroundScope, client)
        val alpha = workspaceRoom("!alpha:example.org", "Alpha")
        workspace.open(alpha)
        runCurrent()
        val current = requireNotNull(workspace.selected.value)
        val composer = requireNotNull(current.composer)
        composer.state.first { !it.loading }
        composer.edit("Keep this even while storage is unavailable")
        saveStarted.await()

        workspace.back()
        runCurrent()
        try {
            assertSame("The channel must stay mounted while saving before Back", current, workspace.selected.value)
        } finally {
            allowSave.complete(Unit)
        }
        composer.state.first { it.error != null }
        runCurrent()
        assertSame("A failed save must keep the same channel mounted", current, workspace.selected.value)

        workspace.open(workspaceRoom("!beta:example.org", "Beta"))
        assertSame("Opening another channel must wait for the draft save", current, workspace.selected.value)
        runCurrent()
        assertSame("A refused channel change must keep the same channel mounted", current, workspace.selected.value)
        assertEquals("Keep this even while storage is unavailable", workspace.selected.value?.composer?.state?.value?.text)

        client.failSaves = false
        composer.retry()
        workspace.back()
        runCurrent()
        assertNull(workspace.selected.value)
        workspace.open(alpha)
        runCurrent()
        val restored = requireNotNull(workspace.selected.value?.composer)
        assertEquals("Keep this even while storage is unavailable", restored.state.first { !it.loading }.text)
        workspace.close()
    }

    @Test fun queuedBackAndRepeatedOpenKeepTheLatestChannelLive() = runTest {
        val workspace = MatrixWorkspace(backgroundScope, WorkspaceClient())
        workspace.open(workspaceRoom("!alpha:example.org", "Alpha"))
        workspace.back()
        val beta = workspaceRoom("!beta:example.org", "Beta")
        workspace.open(beta)
        workspace.open(beta)
        runCurrent()

        assertEquals(beta, workspace.selected.value?.room)
        assertNotNull("The last repeated selection must finish opening", workspace.selected.value?.conversation)
        assertNotNull(workspace.selected.value?.composer)
        workspace.close()
    }

    @Test fun navigationRestoresEachRoomsDraftAndBackReleasesItsSdkResources() = runTest {
        val client = WorkspaceClient()
        val workspace = MatrixWorkspace(backgroundScope, client)
        val alpha = workspaceRoom("!alpha:example.org", "Alpha")
        val beta = workspaceRoom("!beta:example.org", "Beta")

        workspace.open(alpha)
        assertEquals(alpha, workspace.selected.value?.room)
        runCurrent()
        val first = workspace.selected.value!!
        assertNotNull("An opened channel must expose its live timeline", first.conversation)
        val composer = requireNotNull(first.composer)
        composer.state.first { !it.loading }
        composer.edit("Finish Alpha tomorrow")

        workspace.open(beta)
        assertSame("Keep Alpha mounted until its draft is saved", first, workspace.selected.value)
        runCurrent()
        assertEquals(beta, workspace.selected.value?.room)
        val betaComposer = requireNotNull(workspace.selected.value?.composer)
        betaComposer.state.first { !it.loading }
        assertEquals("", betaComposer.state.value.text)
        betaComposer.edit("Beta has a different draft")

        workspace.open(alpha)
        runCurrent()
        val restored = requireNotNull(workspace.selected.value?.composer)
        assertEquals("Finish Alpha tomorrow", restored.state.first { !it.loading }.text)
        restored.edit("Last edit before Back")
        val beforeBack = workspace.selected.value
        workspace.back()
        assertSame("Keep the channel mounted until its draft is saved", beforeBack, workspace.selected.value)
        runCurrent()
        assertNull(workspace.selected.value)
        assertEquals(true, client.handles.all { it.uniffiIsDestroyed })

        workspace.open(alpha)
        runCurrent()
        val reopened = requireNotNull(workspace.selected.value?.composer)
        assertEquals("Last edit before Back", reopened.state.first { !it.loading }.text)
        workspace.close()
        assertEquals(true, client.handles.all { it.uniffiIsDestroyed })
        assertEquals(false, client.uniffiIsDestroyed)
    }

    // capability: thread.open
    @Test fun aThreadOpensOnItsRootWithADraftApartFromItsChannel() = runTest {
        val client = WorkspaceClient()
        val workspace = MatrixWorkspace(backgroundScope, client)
        val alpha = workspaceRoom("!alpha:example.org", "Alpha")

        workspace.open(alpha, threadRoot = "\$root")
        runCurrent()
        assertEquals("\$root", workspace.selected.value?.threadRoot)
        assertEquals(TimelineFocus.Thread("\$root"), client.focuses.last())
        val reply = requireNotNull(workspace.selected.value?.composer)
        reply.state.first { !it.loading }
        reply.edit("A reply in the thread")

        workspace.open(alpha)
        runCurrent()
        assertEquals(TimelineFocus.Live(true), client.focuses.last())
        val channel = requireNotNull(workspace.selected.value?.composer)
        assertEquals("", channel.state.first { !it.loading }.text)

        workspace.open(alpha, threadRoot = "\$root")
        runCurrent()
        assertEquals("A reply in the thread", requireNotNull(workspace.selected.value?.composer).state.first { !it.loading }.text)
        workspace.close()
    }
}

private class WorkspaceClient(private val beforeSave: suspend () -> Unit = {}) : Client(NoHandle) {
    private val drafts = mutableMapOf<String, ComposerDraft>()
    val handles = mutableListOf<Room>()
    val focuses = mutableListOf<TimelineFocus>()
    var failSaves = false
    override fun getRoom(roomId: String): Room = object : Room(NoHandle) {
        override fun id(): String = roomId
        override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline =
            focuses.add(configuration.focus).let { object : Timeline(NoHandle) {
                override suspend fun addListener(listener: TimelineListener): TaskHandle = object : TaskHandle(NoHandle) {
                    override fun cancel() = Unit
                }
                override suspend fun paginateBackwards(numEvents: UShort): Boolean = true
            } }
        override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? = drafts["$roomId $threadRoot"]
        override suspend fun saveComposerDraft(draft: ComposerDraft, threadRoot: String?) {
            beforeSave()
            check(!failSaves) { "Storage is unavailable" }
            check(!uniffiIsDestroyed) { "The room was closed before its draft was saved" }
            drafts["$roomId $threadRoot"] = draft
        }
        override suspend fun clearComposerDraft(threadRoot: String?) { drafts.remove("$roomId $threadRoot") }
    }.also(handles::add)
}

private fun workspaceRoom(id: String, name: String) = RoomSummary(
    id = id, name = name, direct = false, topic = "", unread = UnreadBadge.None,
    initials = name.take(1), colorIndex = 0,
)
