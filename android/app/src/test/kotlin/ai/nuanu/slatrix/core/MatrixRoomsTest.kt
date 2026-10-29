package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.matrix.rustcomponents.sdk.*
import uniffi.matrix_sdk_base.EncryptionState

class MatrixRoomsTest {
    @Test fun retryKeepsTheLiveSyncUntilNotificationLookupCompletes() = runTest {
        val client = RoomsClient(emptyList())
        val original = RoomsSync()
        val replacement = RoomsSync()
        client.services.trySend(original)
        client.services.trySend(replacement)
        val fetching = CompletableDeferred<Pair<String, String>>()
        val result = CompletableDeferred<NotificationStatus>()
        client.lookup = { roomId, eventId ->
            fetching.complete(roomId to eventId)
            result.await()
        }
        val rooms = MatrixRooms(backgroundScope, client)
        original.started.await()

        val notification = async { rooms.notification("!team:example.org", "\$event") }
        assertEquals("!team:example.org" to "\$event", fetching.await())
        assertSame(original, (client.notificationSetup as NotificationProcessSetup.SingleProcess).syncService)
        rooms.retry()
        original.teardownStarted.await()
        assertFalse("A notification lookup still owns the running sync", original.stopped.isCompleted)

        result.complete(NotificationStatus.EventNotFound)
        assertSame(NotificationStatus.EventNotFound, notification.await())
        replacement.started.await()
        rooms.close()
    }

    @Test fun joinedSpacesExposeSeparateWorkspacesAndNestedChannelMembership() = runTest {
        val client = RoomsClient(listOf(
            TestRoom(roomInfo("!nuanu:example.org", "Nuanu", space = true)),
            TestRoom(roomInfo("!studio:example.org", "Test Studio", space = true)),
            TestRoom(roomInfo("!nested:example.org", "Design", space = true)),
            TestRoom(roomInfo("!work:example.org", "Operations")),
            TestRoom(roomInfo("!test:example.org", "Sandbox")),
            TestRoom(roomInfo("!dm:example.org", "Avery", direct = true)),
            TestRoom(roomInfo("!invited:example.org", "Private", space = true, membership = Membership.INVITED)),
        ))
        client.spaces = RoomsSpaces(mapOf(
            "!nested:example.org" to listOf("!studio:example.org"),
            "!work:example.org" to listOf("!nuanu:example.org"),
            "!test:example.org" to listOf("!nested:example.org"),
        ))
        val rooms = MatrixRooms(backgroundScope, client)
        runCurrent()

        assertEquals(listOf("Design", "Nuanu", "Test Studio"), rooms.state.value.spaces.map { it.name })
        assertEquals(listOf("Nuanu", "Test Studio"), rooms.state.value.spaces.filter { it.isTopLevel }.map { it.name })
        assertEquals(setOf("!nested:example.org", "!studio:example.org"), rooms.state.value.rooms.single { it.name == "Sandbox" }.spaceIds)
        assertEquals(setOf("!nuanu:example.org"), rooms.state.value.rooms.single { it.name == "Operations" }.spaceIds)
        assertEquals(emptySet<String>(), rooms.state.value.rooms.single { it.direct }.spaceIds)
        rooms.close()
    }

    @Test fun cachedJoinedConversationsAppearBeforeSyncFinishes() = runTest {
        val client = RoomsClient(listOf(
            TestRoom(roomInfo("!z:example.org", "Zebra", direct = true, messages = 3u)),
            TestRoom(roomInfo("!a:example.org", "Alpha")),
            TestRoom(roomInfo("!space:example.org", "Workspace", space = true)),
            TestRoom(roomInfo("!invite:example.org", "Invitation", membership = Membership.INVITED)),
        ))
        val rooms = MatrixRooms(backgroundScope, client)
        runCurrent()

        assertEquals(listOf("Alpha", "Zebra"), rooms.state.value.rooms.map { it.name })
        assertEquals(UnreadBadge.Count("3"), rooms.state.value.rooms.last().unread)
        assertEquals("Z", rooms.state.value.rooms.last().initials)
        rooms.close()
    }

    @Test fun roomUpdatesMapUnreadAndRemovedRoomsIgnoreLateCallbacks() = runTest {
        val room = TestRoom(roomInfo("!a:example.org", "Alpha", direct = true))
        val client = RoomsClient(listOf(room))
        val sync = RoomsSync()
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        sync.started.await()
        runCurrent()

        room.emit(room.info.copy(displayName = "Renamed", topic = "A topic", numUnreadMessages = ULong.MAX_VALUE))
        runCurrent()
        val renamed = rooms.state.value.rooms.single()
        assertEquals("Renamed", renamed.name)
        assertEquals("A topic", renamed.topic)
        assertEquals(UnreadBadge.Count("99+"), renamed.unread)

        client.cached = emptyList()
        sync.emitEntries(listOf(RoomListEntriesUpdate.PopBack))
        runCurrent()
        assertEquals(emptyList<RoomSummary>(), rooms.state.value.rooms)
        room.emit(room.info.copy(displayName = "Stale room"))
        runCurrent()
        assertEquals(emptyList<RoomSummary>(), rooms.state.value.rooms)
        rooms.close()
    }

    @Test fun retryReplacesFailedSyncAndIgnoresItsLateErrorsAndRooms() = runTest {
        val room = TestRoom(roomInfo("!a:example.org", "Alpha"))
        val client = RoomsClient(listOf(room))
        val failed = RoomsSync()
        val replacement = RoomsSync()
        client.services.trySend(failed)
        client.services.trySend(replacement)
        val rooms = MatrixRooms(backgroundScope, client)
        failed.started.await()
        failed.emitState(SyncServiceState.ERROR)
        runCurrent()
        assertNotNull(rooms.state.value.error)

        rooms.retry()
        replacement.started.await()
        failed.stopped.await()
        runCurrent()
        assertNull(rooms.state.value.error)
        failed.emitState(SyncServiceState.ERROR)
        failed.emitEntries(listOf(RoomListEntriesUpdate.Reset(listOf(TestRoom(roomInfo("!stale:example.org", "Stale"))))))
        runCurrent()
        assertNull(rooms.state.value.error)
        assertEquals(listOf("Alpha"), rooms.state.value.rooms.map { it.name })
        rooms.close()
        replacement.stopped.await()
    }

    @Test fun closeStopsEvenSyncThatFinishesAfterCancellationAndRejectsLateRoomChanges() = runTest {
        val room = TestRoom(roomInfo("!a:example.org", "Alpha"))
        val finishing = CompletableDeferred<SyncService>()
        val entered = CompletableDeferred<Unit>()
        val client = RoomsClient(listOf(room))
        client.finish = {
            entered.complete(Unit)
            withContext(NonCancellable) { finishing.await() }
        }
        val rooms = MatrixRooms(backgroundScope, client)
        entered.await()
        runCurrent()
        val beforeClose = rooms.state.value
        val closing = async { rooms.close() }
        runCurrent()
        val lateSync = RoomsSync()
        finishing.complete(lateSync)
        closing.await()
        lateSync.stopped.await()

        room.emit(room.info.copy(displayName = "Too late"))
        runCurrent()
        assertEquals(beforeClose, rooms.state.value)
    }
}

private class RoomsClient(var cached: List<Room>) : Client(NoHandle) {
    var notificationSetup: NotificationProcessSetup? = null
    var lookup: suspend (String, String) -> NotificationStatus = { _, _ -> NotificationStatus.EventNotFound }
    override suspend fun notificationClient(processSetup: NotificationProcessSetup): NotificationClient {
        notificationSetup = processSetup
        return object : NotificationClient(NoHandle) {
            override suspend fun getNotification(roomId: String, eventId: String): NotificationStatus = lookup(roomId, eventId)
        }
    }
    var spaces: SpaceService = RoomsSpaces()
    override suspend fun spaceService(): SpaceService = spaces
    val services = Channel<SyncService>(Channel.UNLIMITED)
    var finish: suspend () -> SyncService = { services.receive() }
    override fun rooms(): List<Room> = cached
    override fun syncService(): SyncServiceBuilder = object : SyncServiceBuilder(NoHandle) {
        override fun withOfflineMode(): SyncServiceBuilder = this
        override suspend fun finish(): SyncService = this@RoomsClient.finish()
    }
}

private class TestRoom(var info: RoomInfo) : Room(NoHandle) {
    private var listener: RoomInfoListener? = null
    override fun id(): String = info.id
    override suspend fun roomInfo(): RoomInfo = info
    override fun subscribeToRoomInfoUpdates(listener: RoomInfoListener): TaskHandle {
        this.listener = listener
        return RoomsHandle()
    }
    fun emit(info: RoomInfo) {
        this.info = info
        listener?.call(info)
    }
}

private class RoomsSync : SyncService(NoHandle) {
    val started = CompletableDeferred<Unit>()
    val stopped = CompletableDeferred<Unit>()
    val teardownStarted = CompletableDeferred<Unit>()
    private var stateListener: SyncServiceStateObserver? = null
    private var entriesListener: RoomListEntriesListener? = null
    private var activeFilter = false
    override fun roomListService(): RoomListService = object : RoomListService(NoHandle) {
        override suspend fun allRooms(): RoomList = object : RoomList(NoHandle) {
            override fun close() { super.close(); teardownStarted.complete(Unit) }
            override fun entriesWithDynamicAdapters(pageSize: UInt, listener: RoomListEntriesListener): RoomListEntriesWithDynamicAdaptersResult {
                entriesListener = listener
                return object : RoomListEntriesWithDynamicAdaptersResult(NoHandle) {
                    override fun entriesStream(): TaskHandle = RoomsHandle()
                    override fun controller(): RoomListDynamicEntriesController = object : RoomListDynamicEntriesController(NoHandle) {
                        override fun setFilter(kind: RoomListEntriesDynamicFilterKind): Boolean {
                            activeFilter = kind is RoomListEntriesDynamicFilterKind.All
                            return activeFilter
                        }
                    }
                }
            }
        }
    }
    override fun state(listener: SyncServiceStateObserver): TaskHandle {
        stateListener = listener
        return RoomsHandle()
    }
    override suspend fun start() {
        started.complete(Unit)
        emitState(SyncServiceState.RUNNING)
    }
    override suspend fun stop() { stopped.complete(Unit) }
    fun emitState(state: SyncServiceState) { stateListener?.onUpdate(state) }
    fun emitEntries(updates: List<RoomListEntriesUpdate>) {
        if (activeFilter) entriesListener?.onUpdate(updates)
    }
}

private class RoomsHandle : TaskHandle(NoHandle) {
    override fun cancel() = Unit
}

private fun roomInfo(
    id: String,
    name: String,
    direct: Boolean = false,
    messages: ULong = 0u,
    space: Boolean = false,
    membership: Membership = Membership.JOINED,
) = RoomInfo(
    id = id, encryptionState = EncryptionState.NOT_ENCRYPTED, creators = null,
    displayName = name, rawName = name, topic = null, avatarUrl = null,
    isDirect = direct, isDm = direct, isPublic = null, isSpace = space,
    successorRoom = null, isFavourite = false, isLowPriority = false,
    canonicalAlias = null, alternativeAliases = emptyList(), membership = membership,
    inviter = null, heroes = emptyList(), activeMembersCount = 2u, invitedMembersCount = 0u,
    joinedMembersCount = 2u, activeServiceMembersCount = 0u, serviceMembers = emptyList(),
    highlightCount = 0u, notificationCount = 0u, cachedUserDefinedNotificationMode = null,
    hasRoomCall = false, activeRoomCallParticipants = emptyList(),
    activeRoomCallConsensusIntent = RtcCallIntentConsensus.None, isMarkedUnread = false,
    numUnreadMessages = messages, numUnreadNotifications = 0u, numUnreadMentions = 0u,
    fullyReadEventId = null, pinnedEventIds = emptyList(), joinRule = null,
    historyVisibility = RoomHistoryVisibility.Shared, powerLevels = null, roomVersion = null,
    privilegedCreatorsRole = false,
)

private class RoomsSpaces(private val parents: Map<String, List<String>> = emptyMap()) : SpaceService(NoHandle) {
    override suspend fun topLevelJoinedSpaces(): List<SpaceRoom> = emptyList()
    override suspend fun joinedParentIdsOfChild(childId: String): List<String> = parents[childId].orEmpty()
}
