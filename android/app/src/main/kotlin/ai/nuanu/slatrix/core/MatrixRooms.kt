package ai.nuanu.slatrix.core

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.Membership
import org.matrix.rustcomponents.sdk.Room
import org.matrix.rustcomponents.sdk.RoomInfo
import org.matrix.rustcomponents.sdk.RoomInfoListener
import org.matrix.rustcomponents.sdk.RoomList
import org.matrix.rustcomponents.sdk.RoomListDynamicEntriesController
import org.matrix.rustcomponents.sdk.RoomListEntriesDynamicFilterKind
import org.matrix.rustcomponents.sdk.RoomListEntriesListener
import org.matrix.rustcomponents.sdk.RoomListEntriesUpdate
import org.matrix.rustcomponents.sdk.RoomListEntriesWithDynamicAdaptersResult
import org.matrix.rustcomponents.sdk.RoomNotificationMode
import org.matrix.rustcomponents.sdk.SpaceService
import org.matrix.rustcomponents.sdk.SyncService
import org.matrix.rustcomponents.sdk.SyncServiceState
import org.matrix.rustcomponents.sdk.SyncServiceStateObserver
import org.matrix.rustcomponents.sdk.TaskHandle

data class RoomSummary(
    val id: String,
    val name: String,
    val direct: Boolean,
    val topic: String,
    val unread: UnreadBadge,
    val initials: String,
    val colorIndex: Int,
    val spaceIds: Set<String> = emptySet(),
)

data class SpaceSummary(
    val id: String,
    val name: String,
    val isTopLevel: Boolean = true,
    val initials: String = AvatarPlaceholder.initials(name),
    val colorIndex: Int = AvatarPlaceholder.colorIndex(name),
)

data class RoomListState(
    val rooms: List<RoomSummary> = emptyList(),
    val loading: Boolean = true,
    val error: String? = null,
    val spaces: List<SpaceSummary> = emptyList(),
)

class MatrixRooms(scope: CoroutineScope, private val client: Client) {
    private val mutableState = MutableStateFlow(RoomListState())
    val state: StateFlow<RoomListState> = mutableState.asStateFlow()
    private val events = Channel<Event>(Channel.UNLIMITED)
    private val retries = Channel<Unit>(Channel.CONFLATED)
    private val summaries = mutableMapOf<String, RoomSummary>()
    private val spaces = mutableMapOf<String, SpaceSummary>()
    private var parents: Map<String, List<String>> = emptyMap()
    private val spaceRequests = Channel<Long>(Channel.CONFLATED)
    private val spaceGeneration = AtomicLong()
    private val roomHandles = mutableMapOf<String, TaskHandle>()
    private val roomTokens = mutableMapOf<String, Any>()
    private val syncGeneration = AtomicLong()
    private val worker = scope.launch {
        try {
            coroutineScope {
                launch { sync() }
                refresh(client.rooms(), replace = true)
                launch { refreshSpaces() }
                for (event in events) {
                    when (event) {
                        is Event.Info -> if (roomTokens[event.info.id] === event.token) {
                            val wasSpace = event.info.id in spaces
                            val wasJoined = wasSpace || event.info.id in summaries
                            accept(event.info)
                            publish()
                            if (event.info.isSpace || wasSpace || wasJoined != (event.info.membership == Membership.JOINED)) requestSpaces()
                        }
                        is Event.Spaces -> if (event.generation == spaceGeneration.get()) {
                            if (event.parents != null) parents = event.parents
                            publish(event.error)
                        }
                        is Event.Entries -> {
                            if (event.generation != syncGeneration.get()) continue
                            val changed = event.updates.flatMap {
                                when (it) {
                                    is RoomListEntriesUpdate.Append -> it.values
                                    is RoomListEntriesUpdate.Reset -> it.values
                                    is RoomListEntriesUpdate.PushFront -> listOf(it.value)
                                    is RoomListEntriesUpdate.PushBack -> listOf(it.value)
                                    is RoomListEntriesUpdate.Insert -> listOf(it.value)
                                    is RoomListEntriesUpdate.Set -> listOf(it.value)
                                    else -> emptyList()
                                }
                            }
                            if (event.updates.any {
                                it is RoomListEntriesUpdate.Clear || it is RoomListEntriesUpdate.Remove ||
                                    it is RoomListEntriesUpdate.PopFront || it is RoomListEntriesUpdate.PopBack ||
                                    it is RoomListEntriesUpdate.Truncate
                            }) refresh(client.rooms(), replace = true)
                            else refresh(changed.distinctBy { it.id() }, replace = false)
                        }
                        is Event.Connection -> if (event.generation == syncGeneration.get()) {
                            mutableState.value = mutableState.value.copy(error = event.error)
                        }
                    }
                }
            }
        } finally {
            roomHandles.values.forEach { it.release() }
            roomHandles.clear()
            events.close()
            retries.close()
            spaceRequests.close()
        }
    }

    fun retry() { retries.trySend(Unit); requestSpaces() }

    suspend fun close() { worker.cancelAndJoin() }

    private suspend fun refresh(rooms: List<Room>, replace: Boolean) {
        if (replace) {
            val ids = rooms.mapTo(mutableSetOf()) { it.id() }
            summaries.keys.retainAll(ids)
            spaces.keys.retainAll(ids)
            roomHandles.keys.filter { it !in ids }.forEach {
                roomHandles.remove(it)?.release()
                roomTokens.remove(it)
            }
        }
        var error: String? = null
        for (room in rooms) {
            try {
                if (roomHandles[room.id()] == null) {
                    val token = Any()
                    roomTokens[room.id()] = token
                    roomHandles[room.id()] = room.subscribeToRoomInfoUpdates(object : RoomInfoListener {
                        override fun call(roomInfo: RoomInfo) { events.trySend(Event.Info(roomInfo, token)) }
                    })
                }
                val info = room.roomInfo()
                currentCoroutineContext().ensureActive()
                accept(info)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                error = "Couldn’t load some conversations."
            }
        }
        publish(error)
        requestSpaces()
    }

    private fun accept(info: RoomInfo) {
        if (info.membership != Membership.JOINED) {
            summaries.remove(info.id)
            spaces.remove(info.id)
            return
        }
        val name = info.displayName?.takeIf { it.isNotBlank() } ?: info.id
        if (info.isSpace) {
            summaries.remove(info.id)
            spaces[info.id] = SpaceSummary(id = info.id, name = name)
            return
        }
        spaces.remove(info.id)
        summaries[info.id] = RoomSummary(
            id = info.id, name = name, direct = info.isDirect, topic = info.topic.orEmpty(),
            unread = UnreadBadge.forRoom(RoomUnread(
                direct = info.isDirect, muted = info.cachedUserDefinedNotificationMode == RoomNotificationMode.MUTE,
                markedUnread = info.isMarkedUnread, messages = info.numUnreadMessages.clampedLong(),
                notifications = info.numUnreadNotifications.clampedLong(), mentions = info.numUnreadMentions.clampedLong(),
            )),
            initials = AvatarPlaceholder.initials(name), colorIndex = AvatarPlaceholder.colorIndex(name),
        )
    }

    private fun publish(error: String? = null) {
        mutableState.value = mutableState.value.copy(
            rooms = summaries.values.map { it.copy(spaceIds = ancestors(it.id)) }
                .sortedWith(compareBy<RoomSummary, String>(String.CASE_INSENSITIVE_ORDER) { it.name }.thenBy { it.id }),
            spaces = spaces.values.map { it.copy(isTopLevel = parents[it.id].isNullOrEmpty()) }
                .sortedWith(compareBy<SpaceSummary, String>(String.CASE_INSENSITIVE_ORDER) { it.name }.thenBy { it.id }),
            loading = false,
            error = error ?: mutableState.value.error,
        )
    }

    private fun ancestors(id: String): Set<String> {
        val result = mutableSetOf<String>()
        val pending = ArrayDeque(parents[id].orEmpty())
        while (pending.isNotEmpty()) {
            val parent = pending.removeLast()
            if (result.add(parent)) pending.addAll(parents[parent].orEmpty())
        }
        return result
    }

    private fun requestSpaces() { spaceRequests.trySend(spaceGeneration.incrementAndGet()) }

    private suspend fun refreshSpaces() {
        var service: SpaceService? = null
        try {
            for (generation in spaceRequests) {
                try {
                    val current = service ?: client.spaceService().also { service = it }
                    currentCoroutineContext().ensureActive()
                    // Parent lookups read the graph; only this call rebuilds it from cached state.
                    current.topLevelJoinedSpaces()
                    val updated = client.rooms().associate { it.id() to current.joinedParentIdsOfChild(it.id()) }
                    currentCoroutineContext().ensureActive()
                    events.trySend(Event.Spaces(updated, generation))
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    events.trySend(Event.Spaces(null, generation, "Couldn’t load workspaces."))
                }
            }
        } finally {
            service?.close()
        }
    }

    private suspend fun sync() {
        while (currentCoroutineContext().isActive) {
            val generation = syncGeneration.incrementAndGet()
            var service: SyncService? = null
            var list: RoomList? = null
            var entries: RoomListEntriesWithDynamicAdaptersResult? = null
            var controller: RoomListDynamicEntriesController? = null
            var stream: TaskHandle? = null
            var stateHandle: TaskHandle? = null
            try {
                service = client.syncService().withOfflineMode().finish()
                currentCoroutineContext().ensureActive()
                stateHandle = service.state(object : SyncServiceStateObserver {
                    override fun onUpdate(state: SyncServiceState) {
                        val error = when (state) {
                            SyncServiceState.ERROR, SyncServiceState.TERMINATED -> "Couldn’t sync conversations."
                            SyncServiceState.OFFLINE -> "You’re offline."
                            else -> null
                        }
                        events.trySend(Event.Connection(error, generation))
                    }
                })
                list = service.roomListService().allRooms()
                // The limit truncates actual room vectors; it does not reserve that capacity.
                entries = list.entriesWithDynamicAdapters(UInt.MAX_VALUE, object : RoomListEntriesListener {
                    override fun onUpdate(roomEntriesUpdate: List<RoomListEntriesUpdate>) {
                        events.trySend(Event.Entries(roomEntriesUpdate, generation))
                    }
                })
                stream = entries.entriesStream()
                controller = entries.controller()
                check(controller.setFilter(RoomListEntriesDynamicFilterKind.All(emptyList())))
                service.start()
                retries.receive()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                events.trySend(Event.Connection("Couldn’t sync conversations.", generation))
                retries.receive()
            } finally {
                stateHandle?.release()
                stream?.release()
                controller?.close()
                entries?.close()
                list?.close()
                withContext(NonCancellable) { runCatching { service?.stop() } }
                service?.close()
            }
        }
    }

    private fun TaskHandle.release() {
        runCatching { cancel() }
        close()
    }

    private fun ULong.clampedLong(): Long = coerceAtMost(Long.MAX_VALUE.toULong()).toLong()

    private sealed interface Event {
        data class Spaces(val parents: Map<String, List<String>>?, val generation: Long, val error: String? = null) : Event
        data class Info(val info: RoomInfo, val token: Any) : Event
        data class Entries(val updates: List<RoomListEntriesUpdate>, val generation: Long) : Event
        data class Connection(val error: String?, val generation: Long) : Event
    }
}
