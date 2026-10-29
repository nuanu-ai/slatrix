package ai.nuanu.slatrix.core

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.plus
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.CreateRoomParameters
import org.matrix.rustcomponents.sdk.Membership
import org.matrix.rustcomponents.sdk.MembershipState
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.RoomMember
import org.matrix.rustcomponents.sdk.RoomPreset
import org.matrix.rustcomponents.sdk.RoomVisibility

/** Someone on the server: their Matrix ID, the name to show and their picture. */
data class Person(val id: String, val name: String, val avatarUrl: String? = null)

/** People the directory found for [query], or why it couldn't search. */
data class PeopleSearchState(val query: String = "", val people: List<Person> = emptyList(), val loading: Boolean = false,
    val error: String? = null)

/** Which direct message Message reuses, as `spec/direct-message.json` has it. */
object DirectMessages {
    /** Reused only while its active members are exactly you, joined, and [target]. */
    fun reusable(members: List<Pair<String, MembershipState>>, me: String, target: String): Boolean {
        val active = members.filter { (_, membership) -> membership == MembershipState.Join || membership == MembershipState.Invite }
        return active.map { it.first }.toSet() == setOf(me, target) && active.any { it == me to MembershipState.Join }
    }
}

/** People's profiles, and the direct message that Message opens with each of them. */
class MatrixPeople(scope: CoroutineScope, private val client: Client) {
    // Its own child, so signing out stops a Message still at work, as the Mac's session check does.
    private val work = scope + SupervisorJob(scope.coroutineContext[Job])
    private val lock = Mutex()
    private val opening = mutableMapOf<String, Deferred<String>>()
    /** A room just made for someone, until sync knows it and the next Message finds it like any other. */
    private val made = mutableMapOf<String, String>()
    private val mutableResults = MutableStateFlow(PeopleSearchState())
    val results: StateFlow<PeopleSearchState> = mutableResults.asStateFlow()
    private val searches = AtomicLong()
    private var searching: Job? = null

    /**
     * Searches the server's user directory for [query], as the Mac does: after a pause in typing, so a query replaced
     * meanwhile never asks, and a full Matrix ID is found even where the directory doesn't list it. A late answer for an
     * older query never lands.
     */
    fun search(query: String) {
        val token = searches.incrementAndGet()
        searching?.cancel()
        val term = query.trim()
        when {
            term.isEmpty() -> return run { mutableResults.value = PeopleSearchState() }
            term.toByteArray().size > 1_024 -> return run { mutableResults.value = PeopleSearchState(term, error = "Use a shorter name or Matrix ID.") }
        }
        // What was found stays until the new answer replaces it, so typing never blanks the list.
        mutableResults.update { it.copy(query = term, loading = true, error = null) }
        searching = work.launch(Dispatchers.Default) {
            delay(250)
            val directory = try {
                client.searchUsers(term, 50u).results
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                null
            }
            val found = directory.orEmpty().filter { ComposerFormat.userID.matches(it.userId) }
                .map { person(it.userId, it.displayName, it.avatarUrl) }.toMutableList()
            if (ComposerFormat.userID.matches(term) && found.none { it.id == term }) {
                // Someone without a public profile can still be messaged by their ID.
                found.add(0, profile(term)?.takeIf { it.id == term } ?: Person(term, term))
            }
            val people = found.distinctBy { it.id }
            mutableResults.update {
                if (searches.get() != token) it
                else PeopleSearchState(term, people, error = if (directory == null && people.isEmpty()) "Couldn’t search people." else null)
            }
        }
    }

    /** [userId]'s profile from the server, or null when it can't be loaded. */
    suspend fun profile(userId: String): Person? = quietly {
        client.getProfile(userId).let { person(it.userId, it.displayName, it.avatarUrl) }
    }

    /** The other person in the direct message [roomId], for its header. */
    suspend fun counterpart(roomId: String): Person? = quietly {
        client.getRoom(roomId)?.use { room ->
            room.roomInfo().heroes.singleOrNull()?.let { person(it.userId, it.displayName, it.avatarUrl) }
        }
    }

    /** Your direct message with [userId] once the room list has it, or null when it couldn't be found or made. */
    suspend fun message(userId: String, rooms: Flow<RoomListState>): RoomSummary? = quietly {
        val id = directRoom(userId)
        // A new room reaches the list with the next sync.
        withTimeoutOrNull(30_000) { rooms.mapNotNull { list -> list.rooms.firstOrNull { it.id == id } }.first() }
    }

    /**
     * The direct message with [userId]: an encrypted one you already share, else a plaintext one once it is encrypted,
     * else a new one. Asking again while one is being made waits for it, so a double tap never makes two.
     */
    suspend fun directRoom(userId: String): String {
        val task = lock.withLock {
            opening[userId]?.takeIf { it.isActive } ?: work.async(Dispatchers.Default) { find(userId) }.also { opening[userId] = it }
        }
        return task.await()
    }

    private suspend fun find(userId: String): String {
        val me = client.userId()
        require(userId != me)
        lock.withLock { made[userId] }?.let { pending ->
            if (client.getRoom(pending)?.also(Room::close) == null) return pending
            lock.withLock { made.remove(userId) }
        }
        val rooms = client.getDmRooms(userId).sortedBy { it.id() }
        try {
            var plaintext: Room? = null
            for (room in rooms) {
                if (room.membership() != Membership.JOINED || !room.isDirect() || !reusable(room, me, userId)) continue
                if (room.isEncrypted()) return room.id()
                if (plaintext == null) plaintext = room
            }
            plaintext?.let { room ->
                room.enableEncryption()
                return room.id()
            }
        } finally {
            rooms.forEach(Room::close)
        }
        val id = client.createRoom(CreateRoomParameters(name = null, isEncrypted = true, isDirect = true,
            visibility = RoomVisibility.Private, preset = RoomPreset.TRUSTED_PRIVATE_CHAT, invite = listOf(userId)))
        lock.withLock { made[userId] = id }
        return id
    }

    private suspend fun reusable(room: Room, me: String, target: String): Boolean {
        val members = mutableListOf<RoomMember>()
        room.members().use { iterator ->
            while (true) members += iterator.nextChunk(100u)?.takeIf { it.isNotEmpty() } ?: break
        }
        return DirectMessages.reusable(members.map { it.userId to it.membership }, me, target)
    }

    /** Stops any Message still at work; the account is going. */
    fun close() = work.cancel()

    private fun person(id: String, name: String?, avatarUrl: String?) = Person(id, name?.takeIf(String::isNotBlank) ?: id, avatarUrl)

    private suspend fun <T> quietly(block: suspend () -> T): T? = withContext(Dispatchers.Default) {
        try { block() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
    }
}
