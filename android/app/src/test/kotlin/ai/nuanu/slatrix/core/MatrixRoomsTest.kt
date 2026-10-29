package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.matrix.rustcomponents.sdk.*
import uniffi.matrix_sdk_base.EncryptionState

class MatrixRoomsTest {
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
}

private class RoomsClient(val cached: List<Room>) : Client(NoHandle) {
    val sync = CompletableDeferred<SyncService>()
    override fun rooms(): List<Room> = cached
    override fun syncService(): SyncServiceBuilder = object : SyncServiceBuilder(NoHandle) {
        override fun withOfflineMode(): SyncServiceBuilder = this
        override suspend fun finish(): SyncService = sync.await()
    }
}

private class TestRoom(val info: RoomInfo) : Room(NoHandle) {
    override fun id(): String = info.id
    override suspend fun roomInfo(): RoomInfo = info
    override fun subscribeToRoomInfoUpdates(listener: RoomInfoListener): TaskHandle = object : TaskHandle(NoHandle) {
        override fun cancel() = Unit
    }
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
