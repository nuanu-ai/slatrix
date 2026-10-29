package ai.nuanu.slatrix.core

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.CreateRoomParameters
import org.matrix.rustcomponents.sdk.JoinRule
import org.matrix.rustcomponents.sdk.PublicRoomJoinRule
import org.matrix.rustcomponents.sdk.RoomDescription
import org.matrix.rustcomponents.sdk.RoomDirectorySearchEntriesListener
import org.matrix.rustcomponents.sdk.RoomDirectorySearchEntryUpdate
import org.matrix.rustcomponents.sdk.RoomPreset
import org.matrix.rustcomponents.sdk.RoomType
import org.matrix.rustcomponents.sdk.RoomVisibility
import org.matrix.rustcomponents.sdk.SpaceRoom
import uniffi.matrix_sdk_ui.SpaceRoomListPaginationState
import uniffi.ruma_events.StateEventType

/**
 * A channel you can find, in the server's public directory or a workspace's list. [rule] says who may join when you
 * can't: blank for anyone.
 */
data class DirectoryChannel(val id: String, val name: String, val topic: String?, val members: Long, val canJoin: Boolean,
    val rule: String = "", val via: List<String> = emptyList())

data class ChannelDirectoryState(
    val channels: List<DirectoryChannel> = emptyList(),
    val loading: Boolean = false,
    val more: Boolean = false,
    val error: String? = null,
)

/**
 * Browse channels, as the Mac's directory does: a workspace's own channels, read once and filtered as you type, or with
 * no workspace the server's public directory, a page at a time. Each search starts afresh, so a late page from the one
 * before never lands in it.
 */
class ChannelDirectory(private val scope: CoroutineScope, private val client: Client, private val spaceId: String?) {
    private val mutableState = MutableStateFlow(ChannelDirectoryState(loading = true))
    val state: StateFlow<ChannelDirectoryState> = mutableState.asStateFlow()
    private val generation = AtomicLong()
    private var job: Job? = null
    private var more: Channel<Unit>? = null
    private var workspaceChannels: List<DirectoryChannel>? = null

    fun search(query: String) {
        val token = generation.incrementAndGet()
        job?.cancel()
        val term = query.trim()
        val requests = Channel<Unit>(Channel.CONFLATED).also { more = it }
        // What was listed stays until the new results replace it, so typing never blanks the list.
        mutableState.update { it.copy(loading = true, more = false, error = null) }
        job = scope.launch(Dispatchers.Default) {
            fun publish(change: (ChannelDirectoryState) -> ChannelDirectoryState) {
                mutableState.update { if (generation.get() == token) change(it) else it }
            }
            try {
                if (spaceId != null) {
                    val all = workspaceChannels ?: workspace(spaceId).also { workspaceChannels = it }
                    publish { ChannelDirectoryState(all.filter { it.matches(term) }) }
                    return@launch
                }
                // Waits out typing, so each keystroke doesn't ask the server.
                if (term.isNotEmpty()) delay(250)
                val search = client.roomDirectorySearch()
                val results = mutableListOf<RoomDescription>()
                val handle = search.results(object : RoomDirectorySearchEntriesListener {
                    override fun onUpdate(roomEntriesUpdate: List<RoomDirectorySearchEntryUpdate>) {
                        val channels = synchronized(results) {
                            roomEntriesUpdate.forEach { results.apply(it) }
                            results.mapNotNull { it.channel() }.distinctBy { it.id }
                        }
                        publish { it.copy(channels = channels) }
                    }
                })
                try {
                    search.search(term.ifEmpty { null }, 50u, null)
                    publish { it.copy(channels = synchronized(results) { results.mapNotNull { r -> r.channel() }.distinctBy { c -> c.id } }) }
                    while (true) {
                        val last = search.isAtLastPage()
                        publish { it.copy(loading = false, more = !last) }
                        if (last) break
                        requests.receive()
                        publish { it.copy(loading = true) }
                        search.nextPage()
                    }
                } finally {
                    runCatching { handle.cancel() }
                    handle.close()
                    search.close()
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                publish { it.copy(loading = false, more = false, error = "Couldn’t load channels.") }
            }
        }
    }

    /** Asks for the next page of the server's directory, once the one before has arrived. */
    fun loadMore() { more?.trySend(Unit) }

    fun close() {
        generation.incrementAndGet()
        job?.cancel()
    }

    private suspend fun workspace(spaceId: String): List<DirectoryChannel> = client.spaceService().use { spaces ->
        spaces.spaceRoomList(spaceId).use { list ->
            // shortcut: stops after 50 pages of the hierarchy, as the Mac does; page on demand if a workspace outgrows it.
            for (page in 0 until 50) {
                if ((list.paginationState() as? SpaceRoomListPaginationState.Idle)?.endReached == true) break
                list.paginate()
            }
            list.rooms().mapNotNull { it.channel() }
        }
    }

    private fun DirectoryChannel.matches(term: String) =
        term.isEmpty() || name.contains(term, ignoreCase = true) || topic?.contains(term, ignoreCase = true) == true

    private fun MutableList<RoomDescription>.apply(update: RoomDirectorySearchEntryUpdate) {
        when (update) {
            is RoomDirectorySearchEntryUpdate.Append -> addAll(update.values)
            is RoomDirectorySearchEntryUpdate.Clear -> clear()
            is RoomDirectorySearchEntryUpdate.PushFront -> add(0, update.value)
            is RoomDirectorySearchEntryUpdate.PushBack -> add(update.value)
            is RoomDirectorySearchEntryUpdate.PopFront -> removeFirstOrNull()
            is RoomDirectorySearchEntryUpdate.PopBack -> removeLastOrNull()
            is RoomDirectorySearchEntryUpdate.Insert -> add(update.index.toInt(), update.value)
            is RoomDirectorySearchEntryUpdate.Set -> set(update.index.toInt(), update.value)
            is RoomDirectorySearchEntryUpdate.Remove -> removeAt(update.index.toInt())
            is RoomDirectorySearchEntryUpdate.Truncate -> subList(update.length.toInt(), size).clear()
            is RoomDirectorySearchEntryUpdate.Reset -> { clear(); addAll(update.values) }
        }
    }
}

/** Joining and creating channels, each opened once the room list has it. */
object Channels {
    /** Joins [channel] and returns it from the room list, or null when it couldn't be joined. */
    suspend fun join(client: Client, channel: DirectoryChannel, rooms: Flow<RoomListState>): RoomSummary? = quietly {
        client.joinRoomByIdOrAlias(channel.id, channel.via).close()
        rooms.listed(channel.id)
    }

    /**
     * Creates a private, encrypted channel, as the Mac does, and adds it to the workspace [spaceId] if there is one. Fails
     * before creating anything when you can't add channels to that workspace.
     */
    suspend fun create(client: Client, name: String, topic: String, spaceId: String?, rooms: Flow<RoomListState>): ChannelCreation =
        withContext(Dispatchers.Default) {
            try {
                if (spaceId != null) {
                    val allowed = client.getRoom(spaceId)?.use { space ->
                        space.getPowerLevels().use { it.canOwnUserSendState(StateEventType.SpaceChild) }
                    } == true
                    if (!allowed) return@withContext ChannelCreation(error = "You can’t add channels to this workspace.")
                }
                val id = client.createRoom(CreateRoomParameters(name = name.trim(), topic = topic.trim().ifEmpty { null },
                    isEncrypted = true, visibility = RoomVisibility.Private, preset = RoomPreset.PRIVATE_CHAT))
                val room = rooms.listed(id) ?: return@withContext ChannelCreation(error = "Created, but it hasn’t arrived yet.")
                val linked = spaceId == null || runCatching { client.spaceService().use { it.addChildToSpace(id, spaceId) } }.isSuccess
                ChannelCreation(room, if (linked) null else "Created, but couldn’t add it to the workspace.")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                ChannelCreation(error = "Couldn’t create the channel.")
            }
        }

    private suspend fun <T> quietly(block: suspend () -> T): T? = withContext(Dispatchers.Default) {
        try { block() } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
    }
}

/** A channel just made, and what went wrong if anything did; [room] is null when it can't be opened. */
data class ChannelCreation(val room: RoomSummary? = null, val error: String? = null)

/** [id] from the room list once sync has it there. */
internal suspend fun Flow<RoomListState>.listed(id: String): RoomSummary? =
    withTimeoutOrNull(30_000) { mapNotNull { list -> list.rooms.firstOrNull { it.id == id } }.first() }

/** A server's directory entry, checked: an ID it really is, and bounded text. */
private fun RoomDescription.channel(): DirectoryChannel? {
    if (!roomId.startsWith("!") || roomId.length > 2_048 || roomId.any(Char::isISOControl)) return null
    fun text(value: String?) = value?.take(4_096)?.trim()?.ifEmpty { null }
    val rule = when (joinRule) {
        PublicRoomJoinRule.PUBLIC -> ""
        PublicRoomJoinRule.KNOCK -> "Request to join"
        PublicRoomJoinRule.RESTRICTED -> "Restricted"
        PublicRoomJoinRule.KNOCK_RESTRICTED -> "Restricted · request to join"
        PublicRoomJoinRule.INVITE -> "Invite only"
        null -> ""
    }
    return DirectoryChannel(roomId, text(name) ?: text(alias) ?: roomId, text(topic), joinedMembers.toLong(),
        canJoin = joinRule == PublicRoomJoinRule.PUBLIC, rule = rule)
}

/** A workspace's channel; nested workspaces and direct messages are not channels. Its members may join a restricted one. */
private fun SpaceRoom.channel(): DirectoryChannel? {
    if (roomType != RoomType.Room || isDirect == true || isDm == true) return null
    if (!roomId.startsWith("!") || roomId.length > 2_048 || roomId.any(Char::isISOControl)) return null
    val rule = joinRule
    val canJoin = rule is JoinRule.Public || rule is JoinRule.Restricted || rule is JoinRule.KnockRestricted
    return DirectoryChannel(roomId, (rawName ?: displayName).take(4_096).trim().ifEmpty { roomId }, topic?.take(4_096)?.trim()?.ifEmpty { null },
        numJoinedMembers.toLong(), canJoin, rule = if (canJoin) "" else if (rule is JoinRule.Knock) "Request to join" else "Invite only",
        via = via)
}
