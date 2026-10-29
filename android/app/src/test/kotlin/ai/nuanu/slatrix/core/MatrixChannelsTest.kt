package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.CreateRoomParameters
import org.matrix.rustcomponents.sdk.JoinRule
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.PublicRoomJoinRule
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.RoomDescription
import org.matrix.rustcomponents.sdk.RoomDirectorySearch
import org.matrix.rustcomponents.sdk.RoomDirectorySearchEntriesListener
import org.matrix.rustcomponents.sdk.RoomDirectorySearchEntryUpdate
import org.matrix.rustcomponents.sdk.RoomPowerLevels
import org.matrix.rustcomponents.sdk.RoomPreset
import org.matrix.rustcomponents.sdk.RoomType
import org.matrix.rustcomponents.sdk.RoomVisibility
import org.matrix.rustcomponents.sdk.SpaceRoom
import org.matrix.rustcomponents.sdk.SpaceRoomList
import org.matrix.rustcomponents.sdk.SpaceService
import org.matrix.rustcomponents.sdk.TaskHandle
import uniffi.matrix_sdk_ui.SpaceRoomListPaginationState
import uniffi.ruma_events.StateEventType

class MatrixChannelsTest {
    // capability: home.browse-channels
    @Test fun theServersDirectoryListsTheChannelsASearchFindsAndWhichCanBeJoined() = runTest {
        val client = ChannelsClient()
        client.directory = listOf(description("!design:example.org", "design", PublicRoomJoinRule.PUBLIC, 12u, "Reviews and crits"),
            description("!board:example.org", "board", PublicRoomJoinRule.INVITE, 3u))
        val directory = ChannelDirectory(backgroundScope, client, null)

        directory.search(" des ")
        val found = directory.state.first { !it.loading && it.channels.size == 2 }

        assertEquals("des", client.filter.await())
        assertEquals(DirectoryChannel("!design:example.org", "design", "Reviews and crits", 12, canJoin = true), found.channels[0])
        assertEquals(DirectoryChannel("!board:example.org", "board", null, 3, canJoin = false, rule = "Invite only"), found.channels[1])
    }

    // capability: home.browse-channels
    @Test fun aWorkspaceListsItsOwnChannelsFilteredAsYouType() = runTest {
        val client = ChannelsClient()
        client.hierarchy = listOf(
            spaceRoom("!design:example.org", "design", JoinRule.Restricted(emptyList()), topic = "Crits"),
            spaceRoom("!ops:example.org", "ops", JoinRule.Public),
            spaceRoom("!nested:example.org", "Nested", JoinRule.Public, type = RoomType.Space),
            spaceRoom("!dm:example.org", "Sam", JoinRule.Invite, direct = true),
        )
        val directory = ChannelDirectory(backgroundScope, client, Harbor)

        directory.search("")
        assertEquals(listOf("design", "ops"), directory.state.first { !it.loading }.channels.map { it.name })
        directory.search("crit")
        val found = directory.state.first { !it.loading && it.channels.size == 1 }.channels.single()
        assertTrue("A workspace's restricted channel admits its members", found.canJoin)
        assertEquals(listOf("example.org"), found.via)
    }

    @Test fun aDirectoryThatFailsSaysSo() = runTest {
        val client = ChannelsClient().apply { directoryFails = true }
        val directory = ChannelDirectory(backgroundScope, client, null)
        directory.search("")
        assertEquals("Couldn’t load channels.", directory.state.first { it.error != null }.error)
    }

    // capability: home.browse-channels
    @Test fun joiningAChannelOpensItOnceTheRoomListHasIt() = runTest {
        val client = ChannelsClient()
        val rooms = MutableStateFlow(RoomListState(loading = false))
        val joining = async { Channels.join(client, DirectoryChannel("!design:example.org", "design", null, 12, true, via = listOf("example.org")), rooms) }
        assertEquals("!design:example.org" to listOf("example.org"), client.joined.await())
        rooms.value = RoomListState(listOf(Design), loading = false)
        assertEquals(Design, joining.await())
    }

    // capability: home.create-channel
    @Test fun aNewChannelIsPrivateEncryptedAndAddedToItsWorkspace() = runTest {
        val client = ChannelsClient()
        val rooms = MutableStateFlow(RoomListState(listOf(Design), loading = false))
        client.createdId = Design.id

        val created = Channels.create(client, " design ", "Reviews ", Harbor, rooms)

        assertEquals(ChannelCreation(Design), created)
        val request = client.created.single()
        assertEquals("design" to "Reviews", request.name to request.topic)
        assertTrue(request.isEncrypted && request.visibility == RoomVisibility.Private && request.preset == RoomPreset.PRIVATE_CHAT)
        assertEquals(listOf(Design.id to Harbor), client.linked)
    }

    @Test fun aChannelIsNotCreatedInAWorkspaceYouCantAddChannelsTo() = runTest {
        val client = ChannelsClient().apply { canManage = false }
        val created = Channels.create(client, "design", "", Harbor, MutableStateFlow(RoomListState(loading = false)))
        assertNull(created.room)
        assertEquals("You can’t add channels to this workspace.", created.error)
        assertTrue(client.created.isEmpty())
    }
}

private const val Harbor = "!harbor:example.org"
private val Design = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)

private class ChannelsClient : Client(NoHandle) {
    var directory = emptyList<RoomDescription>()
    var directoryFails = false
    var hierarchy = emptyList<SpaceRoom>()
    var canManage = true
    var createdId = "!created:example.org"
    val filter = CompletableDeferred<String?>()
    val joined = CompletableDeferred<Pair<String, List<String>>>()
    val created = mutableListOf<CreateRoomParameters>()
    val linked = mutableListOf<Pair<String, String>>()

    override fun roomDirectorySearch(): RoomDirectorySearch = object : RoomDirectorySearch(NoHandle) {
        private var listener: RoomDirectorySearchEntriesListener? = null
        override suspend fun results(listener: RoomDirectorySearchEntriesListener): TaskHandle {
            this.listener = listener
            return object : TaskHandle(NoHandle) { override fun cancel() = Unit }
        }
        override suspend fun search(filter: String?, batchSize: UInt, viaServerName: String?) {
            this@ChannelsClient.filter.complete(filter)
            if (directoryFails) throw IllegalStateException("Directory unavailable")
            listener?.onUpdate(listOf(RoomDirectorySearchEntryUpdate.Reset(directory)))
        }
        override suspend fun isAtLastPage(): Boolean = true
    }

    override suspend fun spaceService(): SpaceService = object : SpaceService(NoHandle) {
        override suspend fun spaceRoomList(spaceId: String): SpaceRoomList = object : SpaceRoomList(NoHandle) {
            override fun paginationState(): SpaceRoomListPaginationState = SpaceRoomListPaginationState.Idle(endReached = true)
            override suspend fun rooms(): List<SpaceRoom> = hierarchy.takeIf { spaceId == Harbor }.orEmpty()
        }
        override suspend fun addChildToSpace(childId: String, spaceId: String) { linked += childId to spaceId }
    }

    override fun getRoom(roomId: String): Room? = if (roomId != Harbor) null else object : Room(NoHandle) {
        override suspend fun getPowerLevels(): RoomPowerLevels = object : RoomPowerLevels(NoHandle) {
            override fun canOwnUserSendState(stateEvent: StateEventType): Boolean = canManage && stateEvent == StateEventType.SpaceChild
        }
    }

    override suspend fun joinRoomByIdOrAlias(roomIdOrAlias: String, serverNames: List<String>): Room {
        joined.complete(roomIdOrAlias to serverNames)
        return object : Room(NoHandle) {}
    }

    override suspend fun createRoom(request: CreateRoomParameters): String {
        created += request
        return createdId
    }
}

private fun description(id: String, name: String, rule: PublicRoomJoinRule, members: ULong, topic: String? = null) =
    RoomDescription(id, name, topic, null, null, rule, false, members)

private fun spaceRoom(id: String, name: String, rule: JoinRule, topic: String? = null, type: RoomType = RoomType.Room,
    direct: Boolean = false) = SpaceRoom(id, null, name, name, topic, null, type, 4u, rule, false, false, direct, 0u, null, null,
    listOf("example.org"), direct)
