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
        val client = WorkspaceClient().also { it.failSaves = true }
        val workspace = MatrixWorkspace(backgroundScope, client)
        val alpha = workspaceRoom("!alpha:example.org", "Alpha")
        workspace.open(alpha)
        runCurrent()
        val composer = requireNotNull(workspace.selected.value?.composer)
        composer.state.first { !it.loading }
        composer.edit("Keep this even while storage is unavailable")
        composer.state.first { it.error != null }

        workspace.back()
        runCurrent()
        assertEquals("A failed save must keep the draft editable", composer, workspace.selected.value?.composer)
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
        assertEquals(beta, workspace.selected.value?.room)
        runCurrent()
        val betaComposer = requireNotNull(workspace.selected.value?.composer)
        betaComposer.state.first { !it.loading }
        assertEquals("", betaComposer.state.value.text)
        betaComposer.edit("Beta has a different draft")

        workspace.open(alpha)
        runCurrent()
        val restored = requireNotNull(workspace.selected.value?.composer)
        assertEquals("Finish Alpha tomorrow", restored.state.first { !it.loading }.text)
        restored.edit("Last edit before Back")
        workspace.back()
        assertNull(workspace.selected.value)
        runCurrent()
        assertEquals(true, client.handles.all { it.uniffiIsDestroyed })

        workspace.open(alpha)
        runCurrent()
        val reopened = requireNotNull(workspace.selected.value?.composer)
        assertEquals("Last edit before Back", reopened.state.first { !it.loading }.text)
        workspace.close()
        assertEquals(true, client.handles.all { it.uniffiIsDestroyed })
        assertEquals(false, client.uniffiIsDestroyed)
    }
}

private class WorkspaceClient(private val beforeSave: suspend () -> Unit = {}) : Client(NoHandle) {
    private val drafts = mutableMapOf<String, ComposerDraft>()
    val handles = mutableListOf<Room>()
    var failSaves = false
    override fun getRoom(roomId: String): Room = object : Room(NoHandle) {
        override fun id(): String = roomId
        override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline =
            object : Timeline(NoHandle) {
                override suspend fun addListener(listener: TimelineListener): TaskHandle = object : TaskHandle(NoHandle) {
                    override fun cancel() = Unit
                }
                override suspend fun paginateBackwards(numEvents: UShort): Boolean = true
            }
        override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? = drafts[roomId]
        override suspend fun saveComposerDraft(draft: ComposerDraft, threadRoot: String?) {
            check(!failSaves) { "Storage is unavailable" }
            beforeSave()
            check(!uniffiIsDestroyed) { "The room was closed before its draft was saved" }
            drafts[roomId] = draft
        }
        override suspend fun clearComposerDraft(threadRoot: String?) { drafts.remove(roomId) }
    }.also(handles::add)
}

private fun workspaceRoom(id: String, name: String) = RoomSummary(
    id = id, name = name, direct = false, topic = "", unread = UnreadBadge.None,
    initials = name.take(1), colorIndex = 0,
)
