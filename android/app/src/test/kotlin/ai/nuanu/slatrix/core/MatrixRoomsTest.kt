package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Test
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
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

        invited.emit(invited.info.copy(membership = Membership.JOINED))
        val joined = rooms.state.first { state -> state.rooms.any { it.spaceIds.isNotEmpty() } }
        assertEquals(setOf("!nuanu:example.org"), joined.rooms.single().spaceIds)
        rooms.close()
    }

    // capability: home.invitations
    @Test fun anInvitationIsListedApartWithWhoSentItUntilItIsJoined() = runTest {
        val sam = RoomMember("@sam:example.org", "Sam Lee", null, null, null, MembershipState.Join, false, PowerLevel.Value(0), false,
            uniffi.matrix_sdk.RoomMemberRole.USER, null, false)
        val invited = TestRoom(roomInfo("!design:example.org", "design", membership = Membership.INVITED, inviter = sam))
        val client = RoomsClient(listOf(invited, TestRoom(roomInfo("!harbor:example.org", "Harbor", space = true, membership = Membership.INVITED))))
        val parents = java.util.concurrent.ConcurrentHashMap<String, List<String>>()
        client.spaces = RoomsSpaces(parents)
        val sync = RoomsSync()
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        sync.started.await()

        val listed = rooms.state.first { it.invitations.size == 2 }
        assertEquals(listOf(Invitation("!design:example.org", "design", inviter = "Sam Lee"),
            Invitation("!harbor:example.org", "Harbor", space = true)), listed.invitations)
        assertEquals(emptyList<RoomSummary>(), listed.rooms)
        assertEquals(emptyList<SpaceSummary>(), listed.spaces)

        // Added to a workspace while you were only invited, it lands there once joined.
        parents["!design:example.org"] = listOf("!ops:example.org")
        invited.emit(invited.info.copy(membership = Membership.JOINED))
        val joined = rooms.state.first { state -> state.rooms.isNotEmpty() }
        assertEquals(listOf("design"), joined.rooms.map { it.name })
        assertEquals(setOf("!ops:example.org"), rooms.state.first { state -> state.rooms.any { it.spaceIds.isNotEmpty() } }.rooms.single().spaceIds)
        assertEquals(listOf("Harbor"), joined.invitations.map { it.name })
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
    @Test fun starredChannelsFollowTheirTag() = runTest {
        val alpha = TestRoom(roomInfo("!a:example.org", "Alpha").copy(isFavourite = true))
        val client = RoomsClient(listOf(alpha, TestRoom(roomInfo("!b:example.org", "Beta"))))
        val rooms = MatrixRooms(backgroundScope, client)
        val state = rooms.state.first { !it.loading }

        assertEquals(listOf("Alpha"), state.rooms.filter { it.starred }.map { it.name })

        // Another client unstars it.
        alpha.emit(alpha.info.copy(isFavourite = false))
        rooms.state.first { state -> state.rooms.none { it.starred } }
        rooms.close()
    }

    @Test fun aChannelIsPrivateAsItsJoinRuleSaysInEverySharedCase() = runTest {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/channel-privacy.json").readText()).asJsonObject
        val cases = spec["cases"].asJsonArray.map { it.asJsonObject }
        fun rule(case: JsonObject) = when (val value = case["joinRule"].takeUnless { it.isJsonNull }?.asString) {
            null -> null
            "public" -> JoinRule.Public
            "invite" -> JoinRule.Invite
            "knock" -> JoinRule.Knock
            "private" -> JoinRule.Private
            "restricted" -> JoinRule.Restricted(emptyList())
            "knock_restricted" -> JoinRule.KnockRestricted(emptyList())
            else -> JoinRule.Custom(value)
        }
        val client = RoomsClient(cases.mapIndexed { index, case ->
            TestRoom(roomInfo("!$index:example.org", case["name"].asString).copy(joinRule = rule(case)))
        })
        val rooms = MatrixRooms(backgroundScope, client)
        val state = rooms.state.first { !it.loading }

        for (case in cases) {
            val name = case["name"].asString
            assertEquals(name, case["private"].asBoolean, state.rooms.single { it.name == name }.isPrivate)
        }
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

    // capability: activity.badge
    @Test fun aSummaryCarriesItsUnreadMentionsForActivity() = runTest {
        val design = TestRoom(roomInfo("!design:example.org", "design").copy(numUnreadMentions = 2u, numUnreadMessages = 5u))
        val rooms = MatrixRooms(backgroundScope, RoomsClient(listOf(design)))
        assertEquals(2L, rooms.state.first { !it.loading }.rooms.single().mentions)
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

    // capability: conversation.mark-read
    // capability: conversation.mark-unread
    @Test fun markingAConversationReadSendsItsReceiptsAndClearsItsFlagAndMarkingItUnreadSetsIt() = runTest {
        val alpha = TestRoom(roomInfo("!a:example.org", "Alpha", messages = 3u))
        val rooms = MatrixRooms(backgroundScope, RoomsClient(listOf(alpha)))

        assertTrue(rooms.setUnread("!a:example.org", false))
        assertEquals(listOf("read", "fully read", "unread false"), alpha.writes)
        assertTrue(rooms.setUnread("!a:example.org", true))
        assertEquals("unread true", alpha.writes.last())
        alpha.failWrites = true
        assertFalse(rooms.setUnread("!a:example.org", false))
        rooms.close()
    }

    // capability: conversation.mark-read
    @Test fun markingEverythingReadReadsEachAndSaysWhichFailed() = runTest {
        val alpha = TestRoom(roomInfo("!a:example.org", "Alpha", messages = 3u))
        val beta = TestRoom(roomInfo("!b:example.org", "Beta", messages = 1u)).apply { failWrites = true }
        val rooms = MatrixRooms(backgroundScope, RoomsClient(listOf(alpha, beta)))

        assertEquals(listOf("!b:example.org"), rooms.markAllRead(listOf("!a:example.org", "!b:example.org")))
        assertEquals("unread false", alpha.writes.last())
        rooms.close()
    }

    // capability: home.workspace-switcher
    @Test fun workspacesAndDirectMessagesCarryTheirPictures() = runTest {
        val client = RoomsClient(listOf(
            TestRoom(roomInfo("!harbor:example.org", "Harbor", space = true).copy(avatarUrl = "mxc://example.org/harbor")),
            TestRoom(roomInfo("!sam:example.org", "Sam", direct = true)
                .copy(heroes = listOf(RoomHero("@sam:example.org", "Sam", "mxc://example.org/sam", null, null)))),
            TestRoom(roomInfo("!team:example.org", "Team")),
        ))
        val rooms = MatrixRooms(backgroundScope, client)
        val state = rooms.state.first { !it.loading && it.spaces.isNotEmpty() }

        assertEquals("mxc://example.org/harbor", state.spaces.single().avatarUrl)
        assertEquals("A direct message shows the other person", "mxc://example.org/sam", state.rooms.single { it.direct }.avatarUrl)
        assertNull(state.rooms.single { it.name == "Team" }.avatarUrl)
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

    // capability: conversation.unread-line
    @Test fun anUnreadRoomKnowsWhereItsUnreadMessagesStart() = runTest {
        val room = TestRoom(roomInfo("!a:example.org", "Alpha", messages = 2u).copy(fullyReadEventId = "\$read"))
        val client = RoomsClient(listOf(room))
        client.services.trySend(RoomsSync())
        val rooms = MatrixRooms(backgroundScope, client)
        assertEquals("\$read", rooms.state.first { !it.loading }.rooms.single().resumeAt)
        rooms.close()
    }

    @Test fun retryReplacesTheSyncAndIgnoresTheOldOnesLateErrorsAndRooms() = runTest {
        val room = TestRoom(roomInfo("!a:example.org", "Alpha"))
        val client = RoomsClient(listOf(room))
        val failed = RoomsSync()
        val replacement = RoomsSync()
        client.services.trySend(failed)
        client.services.trySend(replacement)
        val rooms = MatrixRooms(backgroundScope, client)
        failed.started.await()

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

    // capability: people.presence
    @Test fun aDirectMessageShowsTheOtherPersonsDotOnceConnected() = runTest {
        val avery = roomInfo("!dm:example.org", "Avery", direct = true)
            .copy(heroes = listOf(RoomHero("@avery:example.org", "Avery", null, null, null)))
        val client = RoomsClient(listOf(TestRoom(avery), TestRoom(roomInfo("!work:example.org", "Operations"))))
        val sync = RoomsSync()
        client.services.trySend(sync)
        val states = mapOf("@me:example.org" to "online", "@avery:example.org" to "online")
        val rooms = MatrixRooms(backgroundScope, client, presenceOf = { states[it] })
        val state = rooms.state.first { state -> state.rooms.any { it.presence != null } }
        assertEquals(mapOf("Avery" to Presence.Active, "Operations" to null), state.rooms.associate { it.name to it.presence })
        rooms.close()
    }

    // capability: home.dm-typing
    @Test fun aDirectMessageSaysWhenTheOtherPersonTypesButNotWhenYouDo() = runTest {
        val dm = TestRoom(roomInfo("!dm:example.org", "Avery", direct = true))
        val rooms = MatrixRooms(backgroundScope, RoomsClient(listOf(dm)))
        val typing = dm.typing.filterNotNull().first()
        typing.call(listOf("@me:example.org"))
        typing.call(listOf("@me:example.org", "@avery:example.org"))
        rooms.state.first { it.rooms.single().typing }
        typing.call(listOf("@me:example.org"))
        rooms.state.first { !it.rooms.single().typing }
        rooms.close()
    }

    // capability: app.offline-banner
    @Test fun aDroppedServerConnectionSaysReconnectingUntilSyncAnswersWithoutAnError() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        // The sync running has been handled, so it can't land after the drop.
        client.sendQueuesEnabled.first { it }

        sync.emitState(SyncServiceState.OFFLINE)
        rooms.connection.first { it == ConnectionState.Reconnecting }
        assertNull("The banner says it, so Home's notice doesn't", rooms.state.value.error)
        sync.emitState(SyncServiceState.RUNNING)
        rooms.connection.first { it == ConnectionState.Connected }
        rooms.close()
    }

    // capability: app.offline-banner
    @Test fun aNetworkThatComesBackEndsOfflineAtOnce() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val network = MutableSharedFlow<NetworkStatus>(replay = 1)
        val rooms = MatrixRooms(backgroundScope, client, network = network)
        sync.running.first { it }

        // Offline, the SDK polls the server with pauses that grow to minutes; the phone knows sooner.
        sync.end(SyncServiceState.OFFLINE)
        rooms.connection.first { it == ConnectionState.Reconnecting }
        network.tryEmit(NetworkStatus(true))
        sync.running.first { it }
        rooms.connection.first { it == ConnectionState.Connected }
        rooms.close()
    }

    @Test fun networkRecoveryDoesNotWaitForRoomListWorkToPublishOffline() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        val resuming = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        client.resumeSending = { resuming.complete(Unit); release.await() }
        client.services.trySend(sync)
        val network = MutableSharedFlow<NetworkStatus>()
        val rooms = MatrixRooms(backgroundScope, client, network = network)
        try {
            resuming.await()
            network.subscriptionCount.first { it > 0 }
            sync.end(SyncServiceState.OFFLINE)
            network.emit(NetworkStatus(true))
            release.complete(Unit)
            withContext(Dispatchers.Default) { withTimeout(5_000) { sync.running.first { it } } }
        } finally {
            release.complete(Unit)
            rooms.close()
        }
    }

    @Test fun syncRunsOnlyInTheForegroundWhileAPushStillResolvesItsEvent() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val foreground = MutableStateFlow(false)
        val rooms = MatrixRooms(backgroundScope, client, foreground)

        // The lookup waits for the sync on the clock; on the test's virtual time its timeout would fire before the rooms publish it.
        assertSame(NotificationStatus.EventNotFound, withContext(Dispatchers.Default) { rooms.notification("!team:example.org", "\$event") })
        assertSame(sync, (client.notificationSetup as NotificationProcessSetup.SingleProcess).syncService)
        sync.stopped.await()
        assertFalse("A hidden app keeps its sync stopped", sync.running.value)
        foreground.value = true
        sync.running.first { it }
        foreground.value = false
        sync.running.first { !it }
        rooms.close()
    }

    @Test fun aNetworkRestartCannotLeaveSyncRunningAfterTheAppIsHidden() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val foreground = MutableStateFlow(true)
        val network = MutableSharedFlow<NetworkStatus>()
        val rooms = MatrixRooms(backgroundScope, client, foreground, network)
        val starting = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        try {
            rooms.connection.first { it == ConnectionState.Connected }
            network.subscriptionCount.first { it > 0 }
            sync.beforeStart = { withContext(NonCancellable) { starting.complete(Unit); release.await() } }
            network.emit(NetworkStatus(true))
            starting.await()
            foreground.value = false
            rooms.connection.first { it == ConnectionState.Paused }
            release.complete(Unit)
            network.emit(NetworkStatus(true))
            sync.stopped.await()
            assertFalse("The app is hidden, so its live sync must stay stopped", sync.running.value)
        } finally {
            release.complete(Unit)
            rooms.close()
        }
    }

    @Test fun changingTheDefaultRouteRestartsAStaleRunningSyncAndResumesSending() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val network = MutableSharedFlow<NetworkStatus>()
        val rooms = MatrixRooms(backgroundScope, client, network = network)
        try {
            client.sendQueuesEnabled.first { it }
            network.subscriptionCount.first { it > 0 }
            client.sendQueuesEnabled.value = false
            network.emit(NetworkStatus(true, routeChanged = true))
            withContext(Dispatchers.Default) {
                withTimeout(5_000) { client.sendQueuesEnabled.first { it } }
            }
            assertEquals(ConnectionState.Connected, rooms.connection.value)
        } finally {
            rooms.close()
        }
    }

    @Test fun returningToTheAppWaitsForANewServerResponse() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val foreground = MutableStateFlow(true)
        val rooms = MatrixRooms(backgroundScope, client, foreground)
        try {
            rooms.connection.first { it == ConnectionState.Connected }
            foreground.value = false
            rooms.connection.first { it == ConnectionState.Paused }
            sync.stopped.await()
            sync.confirmsSync = false
            foreground.value = true
            sync.running.first { it }
            sync.emitEntries(listOf(RoomListEntriesUpdate.Reset(listOf(TestRoom(roomInfo("!team:example.org", "Team"))))))
            rooms.state.first { it.rooms.any { room -> room.name == "Team" } }
            assertEquals(ConnectionState.Reconnecting, rooms.connection.value)
            sync.emitRoomState(RoomListServiceState.RUNNING)
            rooms.connection.first { it == ConnectionState.Connected }
        } finally {
            rooms.close()
        }
    }

    @Test fun aSyncThatEndsWhileTheAppIsOpenRunsAgain() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        sync.running.first { it }

        // Offline mode covers a lost network; a sync that stopped on its own or failed otherwise waits for nobody.
        for (end in listOf(SyncServiceState.TERMINATED, SyncServiceState.ERROR)) {
            sync.end(end)
            withContext(Dispatchers.Default) { withTimeout(5_000) { sync.running.first { it } } }
        }
        rooms.close()
    }

    @Test fun successfulRecoveriesDoNotAccumulateRetryDelays() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        try {
            sync.running.first { it }
            withContext(Dispatchers.Default) {
                withTimeout(5_000) {
                    repeat(8) {
                        sync.end(SyncServiceState.ERROR)
                        sync.running.first { it }
                    }
                }
            }
        } finally {
            rooms.close()
        }
    }

    @Test fun aTemporaryFailurePreparingSyncRecoversWithoutAClick() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        val failNext = java.util.concurrent.atomic.AtomicBoolean(true)
        client.services.trySend(sync)
        client.finish = {
            if (failNext.getAndSet(false)) throw IllegalStateException("Store temporarily busy")
            client.services.receive()
        }
        val rooms = MatrixRooms(backgroundScope, client)
        try {
            withContext(Dispatchers.Default) { withTimeout(5_000) { sync.running.first { it } } }
            assertNull(rooms.state.first { it.error == null }.error)
        } finally {
            rooms.close()
        }
    }

    @Test fun startingSyncDoesNotClaimConnectedBeforeTheServerAnswers() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync().apply { confirmsSync = false }
        client.services.trySend(sync)
        val rooms = MatrixRooms(backgroundScope, client)
        try {
            sync.started.await()
            sync.emitEntries(listOf(RoomListEntriesUpdate.Reset(listOf(TestRoom(roomInfo("!team:example.org", "Team"))))))
            rooms.state.first { it.rooms.any { room -> room.name == "Team" } }
            assertEquals(ConnectionState.Connecting, rooms.connection.value)
            sync.emitRoomState(RoomListServiceState.RUNNING)
            rooms.connection.first { it == ConnectionState.Connected }
        } finally {
            rooms.close()
        }
    }

    @Test fun losingTheNetworkIsDistinctFromWaitingForTheServer() = runTest {
        val client = RoomsClient(emptyList())
        val sync = RoomsSync()
        client.services.trySend(sync)
        val network = MutableStateFlow(NetworkStatus(true))
        val rooms = MatrixRooms(backgroundScope, client, network = network)
        try {
            rooms.connection.first { it == ConnectionState.Connected }
            network.value = NetworkStatus(false)
            withContext(Dispatchers.Default) { withTimeout(5_000) { rooms.connection.first { it == ConnectionState.Offline } } }
            sync.confirmsSync = false
            sync.end(SyncServiceState.OFFLINE)
            network.value = NetworkStatus(true)
            rooms.connection.first { it == ConnectionState.Reconnecting }
            sync.emitRoomState(RoomListServiceState.RUNNING)
            rooms.connection.first { it == ConnectionState.Connected }
        } finally {
            rooms.close()
        }
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
    var resumeSending: suspend () -> Unit = {}
    override suspend fun enableAllSendQueues(enable: Boolean) { resumeSending(); sendQueuesEnabled.value = enable }
    var spaces: SpaceService = RoomsSpaces()
    override suspend fun spaceService(): SpaceService = spaces
    val services = Channel<SyncService>(Channel.UNLIMITED)
    var finish: suspend () -> SyncService = { services.receive() }
    override fun rooms(): List<Room> = cached
    override fun userId(): String = "@me:example.org"
    override fun getRoom(roomId: String): Room? = cached.firstOrNull { it.id() == roomId }
    override fun syncService(): SyncServiceBuilder = object : SyncServiceBuilder(NoHandle) {
        override fun withOfflineMode(): SyncServiceBuilder = this
        override suspend fun finish(): SyncService = this@RoomsClient.finish()
    }
}

private class TestRoom(var info: RoomInfo, var latest: LatestEventValue = LatestEventValue.None) : Room(NoHandle) {
    private var listener: RoomInfoListener? = null
    val typing = MutableStateFlow<TypingNotificationsListener?>(null)
    override fun ownUserId(): String = "@me:example.org"
    override fun subscribeToTypingNotifications(listener: TypingNotificationsListener): TaskHandle {
        typing.value = listener
        return RoomsHandle()
    }
    var unreadable = false
    var favourite: Boolean? = null
    var failFavourite = false
    val writes = mutableListOf<String>()
    var failWrites = false
    override suspend fun markAsRead(receiptType: ReceiptType) {
        if (failWrites) throw IllegalStateException("Offline")
        writes += if (receiptType == ReceiptType.READ) "read" else "fully read"
    }
    override suspend fun setUnreadFlag(newValue: Boolean) {
        if (failWrites) throw IllegalStateException("Offline")
        writes += "unread $newValue"
    }
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
    var beforeStart: suspend () -> Unit = {}
    var confirmsSync = true
    private var roomStateListener: RoomListServiceStateListener? = null
    val started = CompletableDeferred<Unit>()
    val stopped = CompletableDeferred<Unit>()
    val teardownStarted = CompletableDeferred<Unit>()
    private var stateListener: SyncServiceStateObserver? = null
    private var entriesListener: RoomListEntriesListener? = null
    private var activeFilter = false
    override fun roomListService(): RoomListService = object : RoomListService(NoHandle) {
        override fun state(listener: RoomListServiceStateListener): TaskHandle {
            roomStateListener = listener
            listener.onUpdate(RoomListServiceState.INITIAL)
            return RoomsHandle()
        }
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
        beforeStart()
        if (running.value) return
        running.value = true
        emitState(SyncServiceState.RUNNING)
        // Only once its RUNNING is queued, so a state the test emits next lands after it rather than being cleared by it.
        started.complete(Unit)
    }
    override suspend fun stop() {
        running.value = false
        stopped.complete(Unit)
    }
    fun emitState(state: SyncServiceState) {
        stateListener?.onUpdate(state)
        if (confirmsSync && state == SyncServiceState.RUNNING) emitRoomState(RoomListServiceState.RUNNING)
    }
    fun emitRoomState(state: RoomListServiceState) { roomStateListener?.onUpdate(state) }
    fun end(state: SyncServiceState) {
        running.value = false
        emitState(state)
    }
    fun emitEntries(updates: List<RoomListEntriesUpdate>) {
        if (activeFilter) entriesListener?.onUpdate(updates)
    }
}

/** What you may do in a room; the event type objects compare through the SDK, so they're told apart by type. */
internal class TestPowers(private val post: Boolean = true, private val name: Boolean = true, private val topic: Boolean = true,
    private val invite: Boolean = true, private val pin: Boolean = true, private val spaceChild: Boolean = true) : RoomPowerLevels(NoHandle) {
    override fun canOwnUserSendMessage(message: MessageLikeEventType): Boolean = post || message !is MessageLikeEventType.RoomMessage
    override fun canOwnUserSendState(stateEvent: StateEventType): Boolean = when (stateEvent) {
        is StateEventType.RoomName -> name
        is StateEventType.RoomTopic -> topic
        is StateEventType.SpaceChild -> spaceChild
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
    inviter: RoomMember? = null,
) = RoomInfo(
    id = id, encryptionState = EncryptionState.NOT_ENCRYPTED, creators = null,
    displayName = name, rawName = name, topic = null, avatarUrl = null,
    isDirect = direct, isDm = direct, isPublic = null, isSpace = space,
    successorRoom = null, isFavourite = false, isLowPriority = false,
    canonicalAlias = null, alternativeAliases = emptyList(), membership = membership,
    inviter = inviter, heroes = emptyList(), activeMembersCount = 2u, invitedMembersCount = 0u,
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
