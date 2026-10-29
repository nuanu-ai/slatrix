package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Test
import org.matrix.rustcomponents.sdk.*
import uniffi.matrix_sdk_base.EncryptionState
import uniffi.ruma_events.MessageLikeEventType
import uniffi.ruma_events.StateEventType

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

        // The lookup's timeout runs on the clock, not the test's virtual time, while the rooms work off the test thread.
        val notification = async(Dispatchers.Default) { rooms.notification("!team:example.org", "\$event") }
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
        val state = rooms.state.first { state -> state.rooms.any { it.name == "Sandbox" && it.spaceIds.isNotEmpty() } }

        assertEquals(listOf("Design", "Nuanu", "Test Studio"), state.spaces.map { it.name })
        assertEquals(listOf("Nuanu", "Test Studio"), state.spaces.filter { it.isTopLevel }.map { it.name })
        assertEquals(setOf("!nested:example.org", "!studio:example.org"), state.rooms.single { it.name == "Sandbox" }.spaceIds)
        assertEquals(setOf("!nuanu:example.org"), state.rooms.single { it.name == "Operations" }.spaceIds)
        assertEquals(emptySet<String>(), state.rooms.single { it.direct }.spaceIds)
        rooms.close()
    }

    @Test fun aChannelJoinedLaterArrivesInItsWorkspace() = runTest {
        val invited = TestRoom(roomInfo("!work:example.org", "Operations", membership = Membership.INVITED))
        val client = RoomsClient(listOf(TestRoom(roomInfo("!nuanu:example.org", "Nuanu", space = true)), invited))
        client.spaces = RoomsSpaces(mapOf("!work:example.org" to listOf("!nuanu:example.org")))
        val sync = RoomsSync()
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        sync.started.await()
        assertEquals(emptyList<RoomSummary>(), rooms.state.first { it.spacesKnown }.rooms)

        invited.info = invited.info.copy(membership = Membership.JOINED)
        sync.emitEntries(listOf(RoomListEntriesUpdate.Set(1u, invited)))
        val joined = rooms.state.first { state -> state.rooms.any { it.spaceIds.isNotEmpty() } }
        assertEquals(setOf("!nuanu:example.org"), joined.rooms.single().spaceIds)
        rooms.close()
    }

    @Test fun aRoomThatCouldNotBeReadIsReadAgainWhenTheListResets() = runTest {
        val room = TestRoom(roomInfo("!a:example.org", "Alpha")).apply { unreadable = true }
        val client = RoomsClient(listOf(room))
        val sync = RoomsSync()
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        sync.started.await()
        assertEquals(emptyList<RoomSummary>(), rooms.state.first { !it.loading }.rooms)

        room.unreadable = false
        sync.emitEntries(listOf(RoomListEntriesUpdate.Reset(listOf(room))))
        assertEquals(listOf("Alpha"), rooms.state.first { it.rooms.isNotEmpty() }.rooms.map { it.name })
        rooms.close()
    }

    // capability: home.starred
    @Test fun starredAndPrivateChannelsFollowTheirTagAndJoinRule() = runTest {
        val alpha = TestRoom(roomInfo("!a:example.org", "Alpha").copy(isFavourite = true, isPublic = false, joinRule = JoinRule.Invite))
        val client = RoomsClient(listOf(alpha, TestRoom(roomInfo("!b:example.org", "Beta").copy(isPublic = true, joinRule = JoinRule.Public)),
            // Slack's public channel: anyone in the workspace can join.
            TestRoom(roomInfo("!c:example.org", "Gamma").copy(isPublic = false, joinRule = JoinRule.Restricted(emptyList()))),
            TestRoom(roomInfo("!d:example.org", "Delta"))))
        val rooms = MatrixRooms(backgroundScope, client)
        val state = rooms.state.first { !it.loading }

        assertEquals(listOf("Alpha"), state.rooms.filter { it.starred }.map { it.name })
        assertEquals(listOf("Alpha"), state.rooms.filter { it.isPrivate }.map { it.name })

        // Another client unstars it.
        alpha.emit(alpha.info.copy(isFavourite = false))
        rooms.state.first { state -> state.rooms.none { it.starred } }
        rooms.close()
    }

    // capability: channel.read-only
    @Test fun whetherYouMayPostFollowsTheRoomsPowerLevels() = runTest {
        val news = TestRoom(roomInfo("!news:example.org", "News"))
        val rooms = MatrixRooms(backgroundScope, RoomsClient(listOf(news)))
        assertTrue("Unknown power levels keep the composer", rooms.state.first { !it.loading }.rooms.single().canPost)

        news.emit(news.info.copy(powerLevels = TestPowers(post = false)))
        rooms.state.first { state -> !state.rooms.single().canPost }
        news.emit(news.info.copy(powerLevels = TestPowers(post = true)))
        rooms.state.first { state -> state.rooms.single().canPost }
        rooms.close()
    }

    // capability: channel.details
    @Test fun aSummaryCarriesItsMemberCountAndWhatYouMayChange() = runTest {
        val design = TestRoom(roomInfo("!design:example.org", "design").copy(joinedMembersCount = 12u))
        val rooms = MatrixRooms(backgroundScope, RoomsClient(listOf(design)))
        val unknown = rooms.state.first { !it.loading }.rooms.single()
        assertEquals(12, unknown.memberCount)
        assertFalse("Unknown power levels offer no edit", unknown.canEditName || unknown.canEditTopic)

        design.emit(design.info.copy(powerLevels = TestPowers(name = false, invite = false)))
        val known = rooms.state.first { state -> state.rooms.single().canEditTopic }.rooms.single()
        assertFalse(known.canEditName)
        assertFalse(known.canInvite)
        rooms.close()
    }

    // capability: conversation.pins
    @Test fun aSummaryCarriesItsPinsInTheOrderPinnedAndWhetherYouMayPin() = runTest {
        val design = TestRoom(roomInfo("!design:example.org", "design").copy(pinnedEventIds = listOf("\$old", "\$new")))
        val rooms = MatrixRooms(backgroundScope, RoomsClient(listOf(design)))
        val unknown = rooms.state.first { !it.loading }.rooms.single()
        assertEquals(listOf("\$old", "\$new"), unknown.pinned)
        assertFalse("Unknown power levels offer no pinning", unknown.canPin)

        design.emit(design.info.copy(powerLevels = TestPowers()))
        rooms.state.first { state -> state.rooms.single().canPin }
        rooms.close()
    }

    // capability: home.star-toggle
    @Test fun starringAConversationTagsItAsAFavourite() = runTest {
        val alpha = TestRoom(roomInfo("!a:example.org", "Alpha"))
        val client = RoomsClient(listOf(alpha))
        val rooms = MatrixRooms(backgroundScope, client)

        assertTrue(rooms.setStarred("!a:example.org", true))
        assertEquals(true, alpha.favourite)
        assertTrue(rooms.setStarred("!a:example.org", false))
        assertEquals(false, alpha.favourite)
        alpha.failFavourite = true
        assertFalse(rooms.setStarred("!a:example.org", true))
        rooms.close()
    }

    @Test fun anAccountWithNoRoomsFinishesLoading() = runTest {
        val rooms = MatrixRooms(backgroundScope, RoomsClient(emptyList()))
        assertEquals(emptyList<RoomSummary>(), rooms.state.first { !it.loading && it.spacesKnown }.rooms)
        rooms.close()
    }

    @Test fun cachedRoomsShowBeforeTheirWorkspacesAreKnown() = runTest {
        val spacesKnown = CompletableDeferred<Unit>()
        val lookingUp = CompletableDeferred<Unit>()
        val client = RoomsClient(listOf(
            TestRoom(roomInfo("!nuanu:example.org", "Nuanu", space = true)),
            TestRoom(roomInfo("!work:example.org", "Operations")),
            TestRoom(roomInfo("!dm:example.org", "Avery", direct = true)),
        ))
        client.spaces = object : SpaceService(NoHandle) {
            override suspend fun topLevelJoinedSpaces(): List<SpaceRoom> {
                lookingUp.complete(Unit)
                spacesKnown.await()
                return emptyList()
            }
            override suspend fun joinedParentIdsOfChild(childId: String): List<String> =
                if (childId == "!work:example.org") listOf("!nuanu:example.org") else emptyList()
        }
        val rooms = MatrixRooms(backgroundScope, client)
        lookingUp.await()
        val cached = rooms.state.first { !it.loading }
        assertFalse(cached.spacesKnown)
        assertEquals(listOf("Avery", "Operations"), cached.rooms.map { it.name })

        spacesKnown.complete(Unit)
        val known = rooms.state.first { it.spacesKnown }
        assertEquals(setOf("!nuanu:example.org"), known.rooms.single { it.name == "Operations" }.spaceIds)
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
        val state = rooms.state.first { !it.loading }

        assertEquals(listOf("Alpha", "Zebra"), state.rooms.map { it.name })
        assertEquals(UnreadBadge.Count("3"), state.rooms.last().unread)
        assertEquals("Z", state.rooms.last().initials)
        rooms.close()
    }

    // capability: home.dms
    @Test fun directMessagesLeadWithTheNewestAndPreviewIt() = runTest {
        val older = TestRoom(roomInfo("!avery:example.org", "Avery", direct = true), latest(1_000u, "See you at noon", own = false))
        val newer = TestRoom(roomInfo("!blake:example.org", "Blake", direct = true), latest(2_000u, "Shipped it", own = true))
        val client = RoomsClient(listOf(older, newer, TestRoom(roomInfo("!team:example.org", "Team"))))
        val rooms = MatrixRooms(backgroundScope, client)
        val state = rooms.state.first { !it.loading }

        assertEquals(listOf("Blake", "Avery"), state.rooms.filter { it.direct }.map { it.name })
        assertEquals(LatestMessage("Shipped it", 2_000, own = true), state.rooms.first { it.name == "Blake" }.latest)

        older.latest = latest(3_000u, "Running late", own = false)
        older.emit(older.info.copy(numUnreadMessages = 1u))
        val updated = rooms.state.first { state -> state.rooms.any { it.latest?.body == "Running late" } }
        assertEquals(listOf("Avery", "Blake"), updated.rooms.filter { it.direct }.map { it.name })
        rooms.close()
    }

    @Test fun anUpdateToOneRoomKeepsEveryOtherRoomsSummary() = runTest {
        val alpha = TestRoom(roomInfo("!a:example.org", "Alpha"))
        val client = RoomsClient(listOf(alpha, TestRoom(roomInfo("!b:example.org", "Beta"))))
        val rooms = MatrixRooms(backgroundScope, client)
        val before = rooms.state.first { !it.loading }.rooms.single { it.name == "Beta" }

        alpha.emit(alpha.info.copy(numUnreadMessages = 2u))
        val after = rooms.state.first { state -> state.rooms.any { it.unread != UnreadBadge.None } }
        assertSame(before, after.rooms.single { it.name == "Beta" })
        rooms.close()
    }

    @Test fun roomUpdatesMapUnreadAndLeftRoomsIgnoreLateCallbacks() = runTest {
        val room = TestRoom(roomInfo("!a:example.org", "Alpha", direct = true))
        val other = TestRoom(roomInfo("!b:example.org", "Beta"))
        val client = RoomsClient(listOf(room, other))
        val sync = RoomsSync()
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        sync.started.await()
        rooms.state.first { !it.loading }

        room.emit(room.info.copy(displayName = "Renamed", topic = "A topic", numUnreadMessages = ULong.MAX_VALUE))
        val renamed = rooms.state.first { state -> state.rooms.any { it.name == "Renamed" } }.rooms.single { it.direct }
        assertEquals("A topic", renamed.topic)
        assertEquals(UnreadBadge.Count("99+"), renamed.unread)

        room.emit(room.info.copy(membership = Membership.LEFT))
        sync.emitEntries(listOf(RoomListEntriesUpdate.Remove(0u)))
        assertEquals(listOf("Beta"), rooms.state.first { state -> state.rooms.none { it.direct } }.rooms.map { it.name })
        room.emit(room.info.copy(displayName = "Stale room", membership = Membership.JOINED))
        other.emit(other.info.copy(displayName = "Beta renamed"))
        assertEquals(listOf("Beta renamed"), rooms.state.first { state -> state.rooms.any { it.name == "Beta renamed" } }.rooms.map { it.name })
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
        assertNotNull(rooms.state.first { it.error != null }.error)

        rooms.retry()
        replacement.started.await()
        failed.stopped.await()
        rooms.state.first { it.error == null }
        failed.emitState(SyncServiceState.ERROR)
        failed.emitEntries(listOf(RoomListEntriesUpdate.Reset(listOf(TestRoom(roomInfo("!stale:example.org", "Stale"))))))
        room.emit(room.info.copy(displayName = "Alpha renamed"))
        val state = rooms.state.first { state -> state.rooms.any { it.name == "Alpha renamed" } }
        assertNull(state.error)
        assertEquals(listOf("Alpha renamed"), state.rooms.map { it.name })
        rooms.close()
        replacement.stopped.await()
    }

    @Test fun aBurstOfMessagesAtABusyAccountsScaleStaysWithinBudget() = runTest {
        val spaces = (0 until 10).map { TestRoom(roomInfo("!space$it:example.org", "Space $it", space = true)) }
        val channels = (0 until 440).map { TestRoom(roomInfo("!c$it:example.org", "channel $it")) }
        val people = (0 until 50).map { TestRoom(roomInfo("!d$it:example.org", "Person $it", direct = true)) }
        val listed = (spaces + channels + people).toMutableList<TestRoom>()
        val client = RoomsClient(listed.toList())
        client.spaces = RoomsSpaces(channels.withIndex().associate { (index, room) -> room.info.id to listOf("!space${index % 10}:example.org") })
        val sync = RoomsSync()
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        sync.started.await()
        sync.emitEntries(listOf(RoomListEntriesUpdate.Reset(listed.toList())))
        rooms.state.first { state -> state.rooms.size == 490 && state.rooms.none { !it.direct && it.spaceIds.isEmpty() } }

        val started = System.nanoTime()
        repeat(300) { message ->
            val room = if (message % 3 == 0) people[message % people.size] else channels[message % channels.size]
            room.emit(room.info.copy(numUnreadMessages = room.info.numUnreadMessages + 1u))
            val index = listed.indexOf(room)
            listed.removeAt(index)
            listed.add(0, room)
            sync.emitEntries(listOf(RoomListEntriesUpdate.Remove(index.toUInt()), RoomListEntriesUpdate.PushFront(room)))
        }
        val last = channels.last()
        last.emit(last.info.copy(displayName = "last message"))
        rooms.state.first { state -> state.rooms.any { it.name == "last message" } }
        val elapsed = (System.nanoTime() - started) / 1_000_000
        assertTrue("300 messages across 500 rooms took $elapsed ms", elapsed < BurstBudgetMillis)
        rooms.close()
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
        val beforeClose = rooms.state.first { !it.loading && it.spacesKnown }
        val closing = async { rooms.close() }
        runCurrent()
        val lateSync = RoomsSync()
        finishing.complete(lateSync)
        closing.await()
        lateSync.stopped.await()

        room.emit(room.info.copy(displayName = "Too late"))
        assertEquals(beforeClose, rooms.state.value)
    }

    // capability: message.send-offline
    @Test fun aSyncThatRunsAgainResumesSendQueuesTheSdkPaused() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        client.sendQueuesEnabled.first { it }
        client.sendQueuesEnabled.value = false

        sync.emitState(SyncServiceState.OFFLINE)
        sync.emitState(SyncServiceState.RUNNING)
        client.sendQueuesEnabled.first { it }
        rooms.close()
    }

    @Test fun syncRunsOnlyInTheForegroundWhileAPushStillResolvesItsEvent() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val foreground = MutableStateFlow(false)
        val rooms = MatrixRooms(backgroundScope, client, foreground)

        assertSame(NotificationStatus.EventNotFound, rooms.notification("!team:example.org", "\$event"))
        assertSame(sync, (client.notificationSetup as NotificationProcessSetup.SingleProcess).syncService)
        sync.stopped.await()
        assertFalse("A hidden app keeps its sync stopped", sync.running.value)
        foreground.value = true
        sync.running.first { it }
        foreground.value = false
        sync.running.first { !it }
        rooms.close()
    }
}

// About three times the 14–38 ms measured locally; rebuilding the whole list per message took 400–750 ms.
private const val BurstBudgetMillis = 120L

private class RoomsClient(var cached: List<Room>) : Client(NoHandle) {
    var notificationSetup: NotificationProcessSetup? = null
    var lookup: suspend (String, String) -> NotificationStatus = { _, _ -> NotificationStatus.EventNotFound }
    override suspend fun notificationClient(processSetup: NotificationProcessSetup): NotificationClient {
        notificationSetup = processSetup
        return object : NotificationClient(NoHandle) {
            override suspend fun getNotification(roomId: String, eventId: String): NotificationStatus = lookup(roomId, eventId)
        }
    }
    val sendQueuesEnabled = MutableStateFlow(false)
    override suspend fun enableAllSendQueues(enable: Boolean) { sendQueuesEnabled.value = enable }
    var spaces: SpaceService = RoomsSpaces()
    override suspend fun spaceService(): SpaceService = spaces
    val services = Channel<SyncService>(Channel.UNLIMITED)
    var finish: suspend () -> SyncService = { services.receive() }
    override fun rooms(): List<Room> = cached
    override fun getRoom(roomId: String): Room? = cached.firstOrNull { it.id() == roomId }
    override fun syncService(): SyncServiceBuilder = object : SyncServiceBuilder(NoHandle) {
        override fun withOfflineMode(): SyncServiceBuilder = this
        override suspend fun finish(): SyncService = this@RoomsClient.finish()
    }
}

private class TestRoom(var info: RoomInfo, var latest: LatestEventValue = LatestEventValue.None) : Room(NoHandle) {
    private var listener: RoomInfoListener? = null
    var unreadable = false
    var favourite: Boolean? = null
    var failFavourite = false
    override suspend fun setIsFavourite(isFavourite: Boolean, tagOrder: Double?) {
        if (failFavourite) throw IllegalStateException("Offline")
        favourite = isFavourite
    }
    override fun id(): String = info.id
    override suspend fun roomInfo(): RoomInfo = if (unreadable) throw IllegalStateException("Store busy") else info
    override suspend fun latestEvent(): LatestEventValue = latest
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
    val running = MutableStateFlow(false)
    override suspend fun start() {
        started.complete(Unit)
        running.value = true
        emitState(SyncServiceState.RUNNING)
    }
    override suspend fun stop() {
        running.value = false
        stopped.complete(Unit)
    }
    fun emitState(state: SyncServiceState) { stateListener?.onUpdate(state) }
    fun emitEntries(updates: List<RoomListEntriesUpdate>) {
        if (activeFilter) entriesListener?.onUpdate(updates)
    }
}

/** What you may do in a room; the event type objects compare through the SDK, so they're told apart by type. */
internal class TestPowers(private val post: Boolean = true, private val name: Boolean = true, private val topic: Boolean = true,
    private val invite: Boolean = true, private val pin: Boolean = true) : RoomPowerLevels(NoHandle) {
    override fun canOwnUserSendMessage(message: MessageLikeEventType): Boolean = post || message !is MessageLikeEventType.RoomMessage
    override fun canOwnUserSendState(stateEvent: StateEventType): Boolean = when (stateEvent) {
        is StateEventType.RoomName -> name
        is StateEventType.RoomTopic -> topic
        else -> true
    }
    override fun canOwnUserInvite(): Boolean = invite
    override fun canOwnUserPinUnpin(): Boolean = pin
}

private class RoomsHandle : TaskHandle(NoHandle) {
    override fun cancel() = Unit
}

internal fun roomInfo(
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

private fun latest(timestamp: ULong, body: String, own: Boolean) = LatestEventValue.Remote(
    timestamp = timestamp, sender = "@sam:example.org", isOwn = own,
    profile = ProfileDetails.Ready("Sam", false, null, null, null),
    content = TimelineItemContent.MsgLike(MsgLikeContent(
        MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent(body, null)), body, false, null)),
        null, null, null,
    )),
)

private class RoomsSpaces(private val parents: Map<String, List<String>> = emptyMap()) : SpaceService(NoHandle) {
    override suspend fun topLevelJoinedSpaces(): List<SpaceRoom> = emptyList()
    override suspend fun joinedParentIdsOfChild(childId: String): List<String> = parents[childId].orEmpty()
}
