package ai.nuanu.slatrix.core

import com.google.gson.JsonParser
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.CreateRoomParameters
import org.matrix.rustcomponents.sdk.Membership
import org.matrix.rustcomponents.sdk.MembershipState
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.PowerLevel
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.RoomHero
import org.matrix.rustcomponents.sdk.RoomHistoryVisibility
import org.matrix.rustcomponents.sdk.RoomInfo
import org.matrix.rustcomponents.sdk.RtcCallIntentConsensus
import uniffi.matrix_sdk_base.EncryptionState
import org.matrix.rustcomponents.sdk.RoomMember
import org.matrix.rustcomponents.sdk.RoomMembersIterator
import org.matrix.rustcomponents.sdk.RoomVisibility
import org.matrix.rustcomponents.sdk.UserProfile

class MatrixPeopleTest {
    @Test fun aDirectMessageIsReusedAsInEverySharedCase() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/direct-message.json").readText()).asJsonObject
        val states = mapOf("join" to MembershipState.Join, "invite" to MembershipState.Invite, "leave" to MembershipState.Leave,
            "ban" to MembershipState.Ban)
        for (item in spec["reuse"].asJsonArray) {
            val case = item.asJsonObject
            val members = case["members"].asJsonArray.map { it.asJsonObject }.map { it["user"].asString to states.getValue(it["membership"].asString) }
            assertEquals(case["name"].asString, case["expected"].asBoolean,
                DirectMessages.reusable(members, spec["me"].asString, spec["target"].asString))
        }
    }

    // capability: people.start-dm
    @Test fun messageReusesAnEncryptedDirectMessageOverAPlaintextOne() = runTest {
        val plaintext = DirectRoom("!a:example.org", encrypted = false)
        val client = PeopleClient(plaintext, DirectRoom("!z:example.org", encrypted = true))
        assertEquals("!z:example.org", MatrixPeople(backgroundScope, client).directRoom(Alice))
        assertFalse(plaintext.encryptionEnabled)
        assertTrue(client.created.isEmpty())
    }

    @Test fun aPlaintextDirectMessageIsEncryptedBeforeItIsReused() = runTest {
        val plaintext = DirectRoom("!a:example.org", encrypted = false)
        assertEquals("!a:example.org", MatrixPeople(backgroundScope, PeopleClient(plaintext)).directRoom(Alice))
        assertTrue(plaintext.encryptionEnabled)
    }

    @Test fun aDirectMessageWithSomeoneElseInItIsNotReused() = runTest {
        val group = DirectRoom("!g:example.org", encrypted = true, extra = "@sam:example.org")
        val client = PeopleClient(group)
        assertEquals("!created:example.org", MatrixPeople(backgroundScope, client).directRoom(Alice))
    }

    // capability: people.start-dm
    @Test fun aNewDirectMessageIsEncryptedPrivateAndInvitesOnlyThePersonOnce() = runTest {
        val client = PeopleClient()
        val creating = CompletableDeferred<Unit>()
        client.createGate = creating
        val people = MatrixPeople(backgroundScope, client)
        val first = async { people.directRoom(Alice) }
        val second = async { people.directRoom(Alice) }
        client.creating.await()
        creating.complete(Unit)

        assertEquals("!created:example.org", first.await())
        assertEquals("!created:example.org", second.await())
        // Until sync lists the new room, Message opens it rather than making another.
        assertEquals("!created:example.org", people.directRoom(Alice))
        val request = client.created.single()
        assertTrue(request.isEncrypted && request.isDirect && request.visibility == RoomVisibility.Private)
        assertEquals(listOf(Alice), request.invite)
    }

    // capability: people.start-dm
    @Test fun messageOpensANewDirectMessageOnceTheRoomListHasIt() = runTest {
        val rooms = MutableStateFlow(RoomListState(loading = false))
        val opening = async { MatrixPeople(backgroundScope, PeopleClient()).message(Alice, rooms) }
        val created = RoomSummary("!created:example.org", "Alice Moss", true, "", UnreadBadge.None, "AM", 0)
        rooms.value = RoomListState(listOf(created), loading = false)
        assertEquals(created, opening.await())
    }

    @Test fun messageIsRefusedOnceTheAccountIsGone() = runTest {
        val client = PeopleClient()
        val people = MatrixPeople(backgroundScope, client)
        people.close()
        assertTrue(runCatching { people.directRoom(Alice) }.exceptionOrNull() is CancellationException)
        assertTrue(client.created.isEmpty())
    }

    // capability: people.profile
    @Test fun aDirectMessagesPersonIsTheOneOtherMemberItNames() = runTest {
        val client = PeopleClient(DirectRoom("!dm:example.org", true, heroes = listOf(hero(Alice, "Alice Moss"))),
            DirectRoom("!group:example.org", true, heroes = listOf(hero(Alice, "Alice Moss"), hero("@sam:example.org", null))))
        val people = MatrixPeople(backgroundScope, client)
        assertEquals(Person(Alice, "Alice Moss"), people.counterpart("!dm:example.org"))
        assertNull("A group conversation names no one person", people.counterpart("!group:example.org"))
    }

    // capability: people.profile
    @Test fun aProfileShowsItsNameOrElseItsMatrixId() = runTest {
        val client = PeopleClient()
        val people = MatrixPeople(backgroundScope, client)
        assertEquals(Person(Alice, "Alice Moss", "mxc://example.org/alice"), people.profile(Alice))
        assertEquals(Person("@quiet:example.org", "@quiet:example.org"), people.profile("@quiet:example.org"))
        assertNull("A profile that can't load is null", people.profile("@gone:example.org"))
    }
}

private const val Me = "@me:example.org"
private const val Alice = "@alice:example.org"

private class PeopleClient(private vararg val rooms: DirectRoom) : Client(NoHandle) {
    val created = mutableListOf<CreateRoomParameters>()
    val creating = CompletableDeferred<Unit>()
    var createGate: CompletableDeferred<Unit>? = null
    override fun userId(): String = Me
    override fun getDmRooms(userId: String): List<Room> = rooms.toList()
    override fun getRoom(roomId: String): Room? = rooms.firstOrNull { it.id() == roomId }
    override suspend fun createRoom(request: CreateRoomParameters): String {
        created += request
        creating.complete(Unit)
        createGate?.await()
        return "!created:example.org"
    }
    override suspend fun getProfile(userId: String): UserProfile = when (userId) {
        Alice -> UserProfile(Alice, "Alice Moss", "mxc://example.org/alice", null, null)
        "@quiet:example.org" -> UserProfile(userId, null, null, null, null)
        else -> throw IllegalStateException("No profile")
    }
}

private class DirectRoom(private val id: String, private var encrypted: Boolean, private val extra: String? = null,
    private val heroes: List<RoomHero> = emptyList()) : Room(NoHandle) {
    override suspend fun roomInfo(): RoomInfo = RoomInfo(
        id = id, encryptionState = EncryptionState.ENCRYPTED, creators = null, displayName = null, rawName = null, topic = null,
        avatarUrl = null, isDirect = true, isDm = true, isPublic = null, isSpace = false, successorRoom = null, isFavourite = false,
        isLowPriority = false, canonicalAlias = null, alternativeAliases = emptyList(), membership = Membership.JOINED, inviter = null,
        heroes = heroes, activeMembersCount = 2u, invitedMembersCount = 0u, joinedMembersCount = 2u, activeServiceMembersCount = 0u,
        serviceMembers = emptyList(), highlightCount = 0u, notificationCount = 0u, cachedUserDefinedNotificationMode = null,
        hasRoomCall = false, activeRoomCallParticipants = emptyList(), activeRoomCallConsensusIntent = RtcCallIntentConsensus.None,
        isMarkedUnread = false, numUnreadMessages = 0u, numUnreadNotifications = 0u, numUnreadMentions = 0u, fullyReadEventId = null,
        pinnedEventIds = emptyList(), joinRule = null, historyVisibility = RoomHistoryVisibility.Shared, powerLevels = null,
        roomVersion = null, privilegedCreatorsRole = false,
    )
    var encryptionEnabled = false
    override fun id(): String = id
    override fun membership(): Membership = Membership.JOINED
    override suspend fun isDirect(): Boolean = true
    override suspend fun isEncrypted(): Boolean = encrypted
    override suspend fun enableEncryption() {
        encryptionEnabled = true
        encrypted = true
    }
    override suspend fun members(): RoomMembersIterator {
        val chunks = ArrayDeque(listOf(listOfNotNull(member(Me, MembershipState.Join), member(Alice, MembershipState.Invite),
            extra?.let { member(it, MembershipState.Join) })))
        return object : RoomMembersIterator(NoHandle) {
            override fun len(): UInt = 3u
            override fun nextChunk(chunkSize: UInt): List<RoomMember>? = chunks.removeFirstOrNull()
        }
    }
    private fun member(id: String, membership: MembershipState) = RoomMember(id, null, null, null, null, membership, false,
        PowerLevel.Value(0), false, uniffi.matrix_sdk.RoomMemberRole.USER, null, false)
}

private fun hero(id: String, name: String?) = RoomHero(id, name, null, null, null)
