package ai.nuanu.slatrix.core

import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.JoinRule
import org.matrix.rustcomponents.sdk.LatestEventValue
import org.matrix.rustcomponents.sdk.MsgLikeKind
import org.matrix.rustcomponents.sdk.NotificationProcessSetup
import org.matrix.rustcomponents.sdk.NotificationStatus
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
import org.matrix.rustcomponents.sdk.TimelineItemContent

data class RoomSummary(
    val id: String,
    val name: String,
    val direct: Boolean,
    val topic: String,
    val unread: UnreadBadge,
    val initials: String,
    val colorIndex: Int,
    val spaceIds: Set<String> = emptySet(),
    val latest: LatestMessage? = null,
    val starred: Boolean = false,
    val isPrivate: Boolean = false,
    val avatarUrl: String? = null,
)

/** A room's newest event; [body] is null when there is nothing to preview, such as a membership change. */
data class LatestMessage(val body: String?, val timestamp: Long, val own: Boolean)

data class SpaceSummary(
    val id: String,
    val name: String,
    val isTopLevel: Boolean = true,
    val initials: String = AvatarPlaceholder.initials(name),
    val colorIndex: Int = AvatarPlaceholder.colorIndex(name),
    val avatarUrl: String? = null,
)

data class RoomListState(
    val rooms: List<RoomSummary> = emptyList(),
    val loading: Boolean = true,
    val error: String? = null,
    val spaces: List<SpaceSummary> = emptyList(),
    /** False until the first space lookup finishes; rooms show at once, with no [RoomSummary.spaceIds] yet. */
    val spacesKnown: Boolean = false,
)

class MatrixRooms(scope: CoroutineScope, internal val client: Client, private val foreground: StateFlow<Boolean> = MutableStateFlow(true)) {
    private val syncLock = Mutex()
    private val activeSync = MutableStateFlow<SyncService?>(null)
    private val mutableState = MutableStateFlow(RoomListState())
    val state: StateFlow<RoomListState> = mutableState.asStateFlow()
    private val events = Channel<Event>(Channel.UNLIMITED)
    private val retries = Channel<Unit>(Channel.CONFLATED)
    private val summaries = mutableMapOf<String, RoomSummary>()
    private val spaces = mutableMapOf<String, SpaceSummary>()
    private var parents: Map<String, List<String>>? = null
    private val spaceRequests = Channel<SpaceRequest>(Channel.UNLIMITED)
    private val followed = mutableMapOf<String, Followed>()
    private val syncGeneration = AtomicLong()
    private var error: String? = null
    // Room calls block on the SDK, so the list never builds on the main thread.
    private val worker = scope.launch(Dispatchers.Default) {
        try {
            coroutineScope {
                launch { sync() }
                launch { refreshSpaces() }
                add(client.rooms())
                // After add's lookup, so the first space result covers the cached rooms, and before publish, so an empty account gets one.
                spaceRequests.trySend(SpaceRequest.Rebuild)
                publish()
                for (first in events) {
                    var event: Event? = first
                    while (event != null) {
                        handle(event)
                        event = events.tryReceive().getOrNull()
                    }
                    publish()
                }
            }
        } finally {
            followed.values.forEach { it.release() }
            followed.clear()
            events.close()
            retries.close()
            spaceRequests.close()
        }
    }

    fun retry() { retries.trySend(Unit); spaceRequests.trySend(SpaceRequest.Rebuild) }

    suspend fun close() { worker.cancelAndJoin() }

    /** Stars or unstars a conversation with Matrix's favourite tag, which the account's other clients show as starred too. */
    suspend fun setStarred(roomId: String, starred: Boolean): Boolean = withContext(Dispatchers.Default) {
        try {
            client.getRoom(roomId)?.use { it.setIsFavourite(starred, null) } != null
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            false
        }
    }

    suspend fun notification(roomId: String, eventId: String): NotificationStatus? = withTimeoutOrNull(15_000) {
        val service = activeSync.filterNotNull().first()
        syncLock.withLock {
            if (activeSync.value !== service) return@withLock null
            client.notificationClient(NotificationProcessSetup.SingleProcess(service)).use {
                it.getNotification(roomId, eventId)
            }
        }
    }

    private suspend fun handle(event: Event) {
        when (event) {
            // A room that stops being joined is released; if it comes back, the list adds it again.
            is Event.Info -> if (followed[event.info.id] === event.room) {
                val wasSpace = event.info.id in spaces
                accept(event.info)
                // Space ancestry changes only with a space.
                if (event.info.isSpace || wasSpace) spaceRequests.trySend(SpaceRequest.Rebuild)
            }
            is Event.Spaces -> {
                if (event.parents != null) {
                    parents = event.parents
                    summaries.replaceAll { _, room -> ancestors(room.id).let { if (it == room.spaceIds) room else room.copy(spaceIds = it) } }
                    spaces.replaceAll { id, space -> topLevel(id).let { if (it == space.isTopLevel) space else space.copy(isTopLevel = it) } }
                } else if (parents == null) {
                    parents = emptyMap()
                }
                if (event.error != null) error = event.error
            }
            // A listed room's own info updates report its changes, leaving included, so only new rooms need reading.
            is Event.Entries -> if (event.generation == syncGeneration.get()) {
                val listed = event.updates.flatMap {
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
                add(listed)
            }
            is Event.Connection -> if (event.generation == syncGeneration.get()) {
                error = event.error
                // A network error pauses a room's send queue; what waited there goes out once sync is back.
                if (event.running) runCatching { client.enableAllSendQueues(true) }
            }
        }
    }

    /** Reads and starts following the rooms in [listed] that aren't followed yet. */
    private suspend fun add(listed: List<Room>) {
        val ids = mutableListOf<String>()
        for (room in listed) {
            var entry: Followed? = null
            try {
                val id = room.id()
                if (id in followed) {
                    room.close()
                    continue
                }
                entry = Followed(room)
                followed[id] = entry
                entry.handle = room.subscribeToRoomInfoUpdates(object : RoomInfoListener {
                    override fun call(roomInfo: RoomInfo) { events.trySend(Event.Info(roomInfo, entry)) }
                })
                val info = room.roomInfo()
                currentCoroutineContext().ensureActive()
                accept(info)
                ids += id
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                // Unfollowed, so the list's next reset reads it again.
                entry?.let { followed.values.remove(it); it.release() } ?: room.close()
                error = "Couldn’t load some conversations."
            }
        }
        if (ids.isEmpty()) return
        if (ids.any { it in spaces }) spaceRequests.trySend(SpaceRequest.Rebuild)
        spaceRequests.trySend(SpaceRequest.Lookup(ids))
    }

    private suspend fun accept(info: RoomInfo) {
        if (info.membership != Membership.JOINED) {
            summaries.remove(info.id)
            spaces.remove(info.id)
            followed.remove(info.id)?.release()
            return
        }
        val name = info.displayName?.takeIf { it.isNotBlank() } ?: info.id
        if (info.isSpace) {
            summaries.remove(info.id)
            val space = SpaceSummary(id = info.id, name = name, isTopLevel = topLevel(info.id), avatarUrl = info.avatarUrl)
            if (spaces[info.id] != space) spaces[info.id] = space
            return
        }
        spaces.remove(info.id)
        val summary = RoomSummary(
            id = info.id, name = name, direct = info.isDirect, topic = info.topic.orEmpty(),
            unread = UnreadBadge.forRoom(RoomUnread(
                direct = info.isDirect, muted = info.cachedUserDefinedNotificationMode == RoomNotificationMode.MUTE,
                markedUnread = info.isMarkedUnread, messages = info.numUnreadMessages.clampedLong(),
                notifications = info.numUnreadNotifications.clampedLong(), mentions = info.numUnreadMentions.clampedLong(),
            )),
            initials = AvatarPlaceholder.initials(name), colorIndex = AvatarPlaceholder.colorIndex(name),
            spaceIds = ancestors(info.id),
            latest = if (info.isDirect) followed[info.id]?.let { latest(it.room) } else null,
            starred = info.isFavourite,
            // A direct message without a picture of its own shows the other person's.
            avatarUrl = info.avatarUrl ?: info.heroes.singleOrNull()?.avatarUrl?.takeIf { info.isDirect },
            // Slack's private channel: only an invitation lets someone in. A restricted room is open to its space, a public channel.
            isPrivate = info.joinRule.let { it is JoinRule.Invite || it is JoinRule.Knock || it is JoinRule.Private },
        )
        // An unchanged room keeps its instance, so its row skips recomposition.
        if (summaries[info.id] != summary) summaries[info.id] = summary
    }

    private suspend fun latest(room: Room): LatestMessage? = try {
        val value = room.latestEvent()
        try {
            when (value) {
                is LatestEventValue.Remote -> LatestMessage(previewText(value.content), value.timestamp.clampedLong(), value.isOwn)
                is LatestEventValue.Local -> LatestMessage(previewText(value.content), value.timestamp.clampedLong(), own = true)
                else -> null
            }
        } finally {
            value.destroy()
        }
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        null
    }

    private fun publish() {
        mutableState.value = RoomListState(
            // Newest first, the key the SDK's recency order uses; channels carry no latest message and fall back to their names.
            rooms = summaries.values.sortedWith(compareByDescending<RoomSummary> { it.latest?.timestamp }
                .thenComparator { a, b -> String.CASE_INSENSITIVE_ORDER.compare(a.name, b.name) }.thenBy { it.id }),
            spaces = spaces.values.sortedWith(compareBy<SpaceSummary, String>(String.CASE_INSENSITIVE_ORDER) { it.name }.thenBy { it.id }),
            loading = false,
            error = error,
            spacesKnown = parents != null,
        )
    }

    private fun topLevel(id: String): Boolean = parents?.get(id).isNullOrEmpty()

    private fun ancestors(id: String): Set<String> {
        val known = parents ?: return emptySet()
        val result = mutableSetOf<String>()
        val pending = ArrayDeque(known[id].orEmpty())
        while (pending.isNotEmpty()) {
            val parent = pending.removeLast()
            if (result.add(parent)) pending.addAll(known[parent].orEmpty())
        }
        return result
    }

    /** Looks up the spaces new rooms sit in. Only a space or membership change rebuilds the graph and rereads every room. */
    private suspend fun refreshSpaces() {
        var service: SpaceService? = null
        var built = false
        val known = mutableMapOf<String, List<String>>()
        try {
            for (first in spaceRequests) {
                var rebuild = !built
                val ids = mutableSetOf<String>()
                var request: SpaceRequest? = first
                while (request != null) {
                    when (request) {
                        SpaceRequest.Rebuild -> rebuild = true
                        is SpaceRequest.Lookup -> ids += request.ids
                    }
                    request = spaceRequests.tryReceive().getOrNull()
                }
                // A failed lookup stays known, so the rebuild that follows a failure rereads it.
                ids.forEach { known.putIfAbsent(it, emptyList()) }
                try {
                    val current = service ?: client.spaceService().also { service = it }
                    currentCoroutineContext().ensureActive()
                    if (rebuild) {
                        // Parent lookups read the graph; only this call rebuilds it from cached state.
                        current.topLevelJoinedSpaces()
                        ids += known.keys
                    }
                    for (id in ids) known[id] = current.joinedParentIdsOfChild(id)
                    built = true
                    currentCoroutineContext().ensureActive()
                    events.trySend(Event.Spaces(known.toMap()))
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    built = false
                    events.trySend(Event.Spaces(null, "Couldn’t load workspaces."))
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
                val current = client.syncService().withOfflineMode().finish()
                service = current
                currentCoroutineContext().ensureActive()
                stateHandle = current.state(object : SyncServiceStateObserver {
                    override fun onUpdate(state: SyncServiceState) {
                        val error = when (state) {
                            SyncServiceState.ERROR, SyncServiceState.TERMINATED -> "Couldn’t sync conversations."
                            SyncServiceState.OFFLINE -> "You’re offline."
                            else -> null
                        }
                        events.trySend(Event.Connection(error, generation, state == SyncServiceState.RUNNING))
                    }
                })
                list = current.roomListService().allRooms()
                // The limit truncates actual room vectors; it does not reserve that capacity.
                entries = list.entriesWithDynamicAdapters(UInt.MAX_VALUE, object : RoomListEntriesListener {
                    override fun onUpdate(roomEntriesUpdate: List<RoomListEntriesUpdate>) {
                        events.trySend(Event.Entries(roomEntriesUpdate, generation))
                    }
                })
                stream = entries.entriesStream()
                controller = entries.controller()
                check(controller.setFilter(RoomListEntriesDynamicFilterKind.All(emptyList())))
                syncLock.withLock { activeSync.value = current }
                coroutineScope {
                    // While the app is hidden, a push lookup runs its own short encryption sync through this service.
                    val visibility = launch { foreground.collect { if (it) current.start() else current.stop() } }
                    retries.receive()
                    visibility.cancel()
                }
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
                withContext(NonCancellable) {
                    syncLock.withLock {
                        if (activeSync.value === service) activeSync.value = null
                        runCatching { service?.stop() }
                        service?.close()
                    }
                }
            }
        }
    }

    private fun TaskHandle.release() {
        runCatching { cancel() }
        close()
    }

    private fun ULong.clampedLong(): Long = coerceAtMost(Long.MAX_VALUE.toULong()).toLong()

    /** A room whose info updates the list follows; it is also the token that tells its callbacks from a released one's. */
    private inner class Followed(val room: Room) {
        var handle: TaskHandle? = null

        fun release() {
            handle?.release()
            room.close()
        }
    }

    private sealed interface SpaceRequest {
        data object Rebuild : SpaceRequest
        data class Lookup(val ids: List<String>) : SpaceRequest
    }

    private sealed interface Event {
        data class Spaces(val parents: Map<String, List<String>>?, val error: String? = null) : Event
        data class Info(val info: RoomInfo, val room: Followed) : Event
        data class Entries(val updates: List<RoomListEntriesUpdate>, val generation: Long) : Event
        data class Connection(val error: String?, val generation: Long, val running: Boolean = false) : Event
    }
}

/** A message's text for a one-line preview; null when there is nothing to show, such as a membership change. */
internal fun previewText(content: TimelineItemContent): String? =
    when (val kind = (content as? TimelineItemContent.MsgLike)?.content?.kind) {
        is MsgLikeKind.Message -> kind.content.body
        is MsgLikeKind.Sticker -> kind.body
        is MsgLikeKind.Poll -> kind.question
        is MsgLikeKind.Redacted -> "This message was deleted"
        is MsgLikeKind.UnableToDecrypt -> "Waiting for this message"
        else -> null
    }
