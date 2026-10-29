package ai.nuanu.slatrix.core

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.*
import uniffi.matrix_sdk.RoomMemberRole
import uniffi.matrix_sdk_base.EncryptionState

class MatrixChannelTest {
    private val room = ChannelRoom(roomInfo("!design:example.org", "design").copy(topic = "Critique"))
    private val settings = ChannelSettings()
    private val channel = MatrixChannel(ChannelClient(room, settings), "!design:example.org")

    // capability: channel.details
    @Test fun savingChangesOnlyWhatChangedAndOnlyWhatYouMay() = runTest {
        channel.save("design", "Launch reviews")
        assertEquals(emptyList<String>(), room.names)
        assertEquals(listOf("Launch reviews"), room.topics)

        assertFailure("Enter a name.") { channel.save(" ", "Critique") }
        room.powers = TestPowers(name = false)
        assertFailure("You don’t have permission to change this conversation’s details.") { channel.save("studio", "Critique") }
        assertEquals(emptyList<String>(), room.names)

        room.powers = TestPowers()
        room.failTopic = true
        assertFailure("The name was saved. The description couldn’t be saved.") { channel.save("studio", "Other") }
        assertEquals(listOf("studio"), room.names)
    }

    @Test fun aDescriptionAloneLeavesAnUnnamedRoomUnnamedAndANameIsTrimmed() = runTest {
        val unnamed = ChannelRoom(roomInfo("!dm:example.org", "Alice").copy(rawName = null))
        val direct = MatrixChannel(ChannelClient(unnamed, settings), "!dm:example.org")
        unnamed.powers = TestPowers(name = false)
        direct.save(null, "Plans")
        assertEquals(emptyList<String>(), unnamed.names)
        assertEquals(listOf("Plans"), unnamed.topics)

        unnamed.powers = TestPowers()
        direct.save(" Trip ", null)
        assertEquals(listOf("Trip"), unnamed.names)
    }

    // capability: conversation.members
    @Test fun membersAreThoseWhoJoinedByName() = runTest {
        room.people = listOf(member("@sam:example.org", "Sam"), member("@ava:example.org", "Ava", MembershipState.Invite),
            member("@zed:example.org", null), member("@ben:example.org", "Ben"))
        assertEquals(listOf("Ben", "Sam", "zed"), channel.members().map { it.name })
    }

    // capability: channel.leave
    @Test fun leavingLeavesTheRoomWhileYoureInIt() = runTest {
        channel.leave()
        assertTrue(room.left)

        room.joined = Membership.LEFT
        assertFailure("You’re no longer in this conversation.") { channel.leave() }
    }

    // capability: channel.invite
    @Test fun invitingNeedsACompleteMatrixIdAndThePowerToInvite() = runTest {
        assertFailure("Enter a complete Matrix ID, such as @name:example.org.") { channel.invite("sam") }
        channel.invite(" @sam:example.org ")
        assertEquals(listOf("@sam:example.org"), room.invited)

        room.powers = TestPowers(invite = false)
        assertFailure("You don’t have permission to invite people here.") { channel.invite("@ava:example.org") }
        assertEquals(listOf("@sam:example.org"), room.invited)
    }

    // capability: conversation.notifications
    @Test fun notificationsFollowTheConversationsOwnChoiceOrTheAccountDefault() = runTest {
        assertEquals(NotificationSetting(NotificationChoice.Default, NotificationChoice.Mentions), channel.notifications())
        channel.setNotifications(NotificationChoice.Nothing)
        assertEquals(NotificationSetting(NotificationChoice.Nothing, NotificationChoice.Mentions), channel.notifications())
        channel.setNotifications(NotificationChoice.Default)
        assertEquals(NotificationSetting(NotificationChoice.Default, NotificationChoice.Mentions), channel.notifications())

        room.encryption = EncryptionState.UNKNOWN
        assertFailure("This conversation is still loading. Try again.") { channel.notifications() }
    }

    @Test fun aServerFailureReadsAsOneMessage() = runTest {
        room.failLeave = true
        assertFailure("Something went wrong. Try again.") { channel.leave() }
    }

    // capability: channel.link-workspace
    @Test fun linkingAddsTheChannelToAWorkspaceYouManageOrTakesItOut() = runTest {
        val studio = ChannelRoom(roomInfo("!studio:example.org", "Studio", space = true))
        val spaces = ChannelSpaces()
        val linked = MatrixChannel(ChannelClient(room, settings, listOf(studio), spaces), "!design:example.org")
        linked.setInWorkspace("!studio:example.org", true)
        linked.setInWorkspace("!studio:example.org", true)
        assertEquals(listOf("!studio:example.org"), spaces.parents["!design:example.org"])
        linked.setInWorkspace("!studio:example.org", false)
        assertEquals(emptyList<String>(), spaces.parents["!design:example.org"])
        assertFailure("This channel isn’t in that workspace.") { linked.setInWorkspace("!studio:example.org", false) }

        studio.powers = TestPowers(spaceChild = false)
        assertFailure("You don’t have permission to manage channels in this workspace.") {
            linked.setInWorkspace("!studio:example.org", true)
        }
        assertEquals(emptyList<String>(), spaces.parents["!design:example.org"])
    }

    private suspend fun assertFailure(message: String, action: suspend () -> Unit) {
        assertEquals(message, runCatching { action() }.exceptionOrNull()?.message)
    }

    private fun member(id: String, name: String?, membership: MembershipState = MembershipState.Join) =
        RoomMember(id, name, null, null, null, membership, false, PowerLevel.Value(0), false, RoomMemberRole.USER, null, false)
}

private class ChannelClient(private val room: Room, private val settings: NotificationSettings,
    private val others: List<Room> = emptyList(), private val spaces: SpaceService = ChannelSpaces()) : Client(NoHandle) {
    override fun getRoom(roomId: String): Room? = (others + room).firstOrNull { it.id() == roomId }
    override suspend fun getNotificationSettings(): NotificationSettings = settings
    override suspend fun spaceService(): SpaceService = spaces
}

/** The spaces graph as the SDK keeps it: each channel's direct parents. */
private class ChannelSpaces : SpaceService(NoHandle) {
    val parents = mutableMapOf<String, MutableList<String>>()
    override suspend fun topLevelJoinedSpaces(): List<SpaceRoom> = emptyList()
    override suspend fun joinedParentIdsOfChild(childId: String): List<String> = parents[childId].orEmpty().toList()
    override suspend fun addChildToSpace(childId: String, spaceId: String) { parents.getOrPut(childId) { mutableListOf() } += spaceId }
    override suspend fun removeChildFromSpace(childId: String, spaceId: String) { parents[childId]?.remove(spaceId) }
}

private class ChannelRoom(private val info: RoomInfo) : Room(NoHandle) {
    var powers: RoomPowerLevels = TestPowers()
    var joined = Membership.JOINED
    var people = emptyList<RoomMember>()
    var encryption = EncryptionState.ENCRYPTED
    var failTopic = false
    var failLeave = false
    var left = false
    val names = mutableListOf<String>()
    val topics = mutableListOf<String>()
    val invited = mutableListOf<String>()
    override fun id(): String = info.id
    override fun isSpace(): Boolean = info.isSpace
    override fun membership(): Membership = joined
    override suspend fun roomInfo(): RoomInfo = info
    override suspend fun getPowerLevels(): RoomPowerLevels = powers
    override suspend fun setName(name: String) { names += name }
    override suspend fun setTopic(topic: String) {
        if (failTopic) throw IllegalStateException("Offline")
        topics += topic
    }
    override suspend fun leave() {
        if (failLeave) throw IllegalStateException("Offline")
        left = true
    }
    override suspend fun inviteUserById(userId: String) { invited += userId }
    override suspend fun latestEncryptionState(): EncryptionState = encryption
    override fun activeMembersCount(): ULong = 5u
    override suspend fun members(): RoomMembersIterator {
        val chunks = mutableListOf(people)
        return object : RoomMembersIterator(NoHandle) {
            override fun len(): UInt = people.size.toUInt()
            override fun nextChunk(chunkSize: UInt): List<RoomMember>? = chunks.removeFirstOrNull()
        }
    }
}

/** The account's rules: a group conversation notifies on mentions unless it has its own choice. */
private class ChannelSettings : NotificationSettings(NoHandle) {
    private val modes = mutableMapOf<String, RoomNotificationMode>()
    override suspend fun getRoomNotificationSettings(roomId: String, isEncrypted: Boolean, isOneToOne: Boolean) =
        modes[roomId]?.let { RoomNotificationSettings(it, false) }
            ?: RoomNotificationSettings(getDefaultRoomNotificationMode(isEncrypted, isOneToOne), true)
    override suspend fun getDefaultRoomNotificationMode(isEncrypted: Boolean, isOneToOne: Boolean) =
        if (isOneToOne) RoomNotificationMode.ALL_MESSAGES else RoomNotificationMode.MENTIONS_AND_KEYWORDS_ONLY
    override suspend fun setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) { modes[roomId] = mode }
    override suspend fun restoreDefaultRoomNotificationMode(roomId: String) { modes.remove(roomId) }
}
