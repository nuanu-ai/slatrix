package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.CreateRoomParameters
import org.matrix.rustcomponents.sdk.JoinRule
import org.matrix.rustcomponents.sdk.Membership
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
    @Test fun joiningAChannelUsesTheServersItCameFrom() = runTest {
        val client = ChannelsClient()
        assertTrue(Channels.join(client, DirectoryChannel("!design:example.org", "design", null, 12, true, via = listOf("example.org"))))
        assertEquals("!design:example.org" to listOf("example.org"), client.joined.await())
        client.joinFails = true
        assertFalse("A refused join says so", Channels.join(client, DirectoryChannel("!ops:example.org", "ops", null, 2, true)))
    }

    // capability: home.create-channel
    @Test fun aNewChannelIsPrivateEncryptedAndAddedToItsWorkspace() = runTest {
        val client = ChannelsClient()
        val rooms = MutableStateFlow(RoomListState(listOf(Design), loading = false))
        client.createdId = Design.id

        val created = Channels.create(client, " design ", "Reviews ", Harbor, rooms)

        assertEquals(ChannelCreation(Design, made = true), created)
        val request = client.created.single()
        assertEquals("design" to "Reviews", request.name to request.topic)
        assertTrue(request.isEncrypted && request.visibility == RoomVisibility.Private && request.preset == RoomPreset.PRIVATE_CHAT)
        assertEquals(listOf(Design.id to Harbor), client.linked)
    }

    @Test fun aChannelTheWorkspaceWontTakeStillOpensAndSaysSo() = runTest {
        val client = ChannelsClient().apply { createdId = Design.id; linkFails = true }
        val created = Channels.create(client, "design", "", Harbor, MutableStateFlow(RoomListState(listOf(Design), loading = false)))
        assertEquals(ChannelCreation(Design, "Created, but couldn’t add it to the workspace.", made = true), created)
    }

    @Test fun theServersDirectoryLoadsItsNextPageWhenAsked() = runTest {
        val client = ChannelsClient()
        client.directory = listOf(description("!design:example.org", "design", PublicRoomJoinRule.PUBLIC, 12u))
        client.nextPage = listOf(description("!ops:example.org", "ops", PublicRoomJoinRule.PUBLIC, 2u))
        val directory = ChannelDirectory(backgroundScope, client, null)

        directory.search("")
        assertTrue(directory.state.first { !it.loading && it.channels.size == 1 }.more)
        directory.loadMore()
        val all = directory.state.first { !it.loading && it.channels.size == 2 }
        assertEquals(listOf("design", "ops"), all.channels.map { it.name })
        assertFalse(all.more)
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
    var joinFails = false
    var linkFails = false
    var nextPage: List<RoomDescription>? = null
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
        private var paged = false
        override suspend fun isAtLastPage(): Boolean = nextPage == null || paged
        override suspend fun nextPage() {
            paged = true
            listener?.onUpdate(listOf(RoomDirectorySearchEntryUpdate.Append(nextPage.orEmpty())))
        }
    }

    override suspend fun spaceService(): SpaceService = object : SpaceService(NoHandle) {
        override suspend fun spaceRoomList(spaceId: String): SpaceRoomList = object : SpaceRoomList(NoHandle) {
            override fun paginationState(): SpaceRoomListPaginationState = SpaceRoomListPaginationState.Idle(endReached = true)
            override suspend fun rooms(): List<SpaceRoom> = hierarchy.takeIf { spaceId == Harbor }.orEmpty()
        }
        override suspend fun addChildToSpace(childId: String, spaceId: String) {
            if (linkFails) throw IllegalStateException("Not ready")
            linked += childId to spaceId
        }
    }

    override fun getRoom(roomId: String): Room? = if (roomId != Harbor) null else object : Room(NoHandle) {
        override fun membership(): Membership = Membership.JOINED
        override suspend fun getPowerLevels(): RoomPowerLevels = object : RoomPowerLevels(NoHandle) {
            override fun canOwnUserSendState(stateEvent: StateEventType): Boolean = canManage && stateEvent is StateEventType.SpaceChild
        }
    }

    override suspend fun joinRoomByIdOrAlias(roomIdOrAlias: String, serverNames: List<String>): Room {
        if (joinFails) throw IllegalStateException("Forbidden")
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
