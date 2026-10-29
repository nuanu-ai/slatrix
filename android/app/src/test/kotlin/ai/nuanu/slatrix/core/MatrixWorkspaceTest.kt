package ai.nuanu.slatrix.core

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.matrix.rustcomponents.sdk.*

class MatrixWorkspaceTest {
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

private class WorkspaceClient : Client(NoHandle) {
    private val drafts = mutableMapOf<String, ComposerDraft>()
    val handles = mutableListOf<Room>()
    override fun getRoom(roomId: String): Room = object : Room(NoHandle) {
        override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline =
            object : Timeline(NoHandle) {
                override suspend fun addListener(listener: TimelineListener): TaskHandle = object : TaskHandle(NoHandle) {
                    override fun cancel() = Unit
                }
                override suspend fun paginateBackwards(numEvents: UShort): Boolean = true
            }
        override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? = drafts[roomId]
        override suspend fun saveComposerDraft(draft: ComposerDraft, threadRoot: String?) { drafts[roomId] = draft }
        override suspend fun clearComposerDraft(threadRoot: String?) { drafts.remove(roomId) }
    }.also(handles::add)
}

private fun workspaceRoom(id: String, name: String) = RoomSummary(
    id = id, name = name, direct = false, topic = "", unread = UnreadBadge.None,
    initials = name.take(1), colorIndex = 0,
)
