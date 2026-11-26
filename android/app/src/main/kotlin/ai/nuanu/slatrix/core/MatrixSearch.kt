package ai.nuanu.slatrix.core

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.ProfileDetails
import org.matrix.rustcomponents.sdk.SearchServiceResult
import org.matrix.rustcomponents.sdk.SearchServiceResultsListener
import org.matrix.rustcomponents.sdk.SearchServiceResultsUpdate
import org.matrix.rustcomponents.sdk.TaskHandle
import uniffi.matrix_sdk.SearchBackfillStrategy
import uniffi.matrix_sdk_ui.SearchServicePaginationState

/** A message the search index matched. */
data class SearchHit(val roomId: String, val eventId: String, val senderId: String, val senderName: String, val body: String,
    val timestamp: Long, val senderAvatarUrl: String? = null)

data class MessageSearchState(
    val query: MessageSearchQuery? = null,
    val hits: List<SearchHit> = emptyList(),
    val loading: Boolean = false,
    val endReached: Boolean = true,
    val indexing: Boolean = false,
    val error: String? = null,
)

/**
 * Searches messages through the SDK's local index, encrypted ones included. Each search gets its own service, so a
 * late page from the one before never lands in the new results.
 */
class MatrixSearch(private val scope: CoroutineScope, private val client: Client,
    private val backfillPollMillis: Long = 750L) {
    private val lock = Any()
    private val mutableState = MutableStateFlow(MessageSearchState())
    val state: StateFlow<MessageSearchState> = mutableState.asStateFlow()
    private val generation = AtomicLong()
    private var job: Job? = null
    private var more: Channel<Unit>? = null
    private var backfill: TaskHandle? = null
    private var backfillWatcher: Job? = null
    private var activeQuery: MessageSearchQuery? = null

    fun search(query: MessageSearchQuery) {
        var newBackfill: TaskHandle? = null
        synchronized(lock) {
            activeQuery = query
            if (backfill == null) {
                val handle = runCatching { client.runSearchBackfill(SearchBackfillStrategy.FOREGROUND) }.getOrNull()
                if (handle != null) {
                    backfill = handle
                    if (!handle.isFinished()) newBackfill = handle
                }
            }
        }
        // The index holds only what this device has seen, so the first search also indexes recent history and refreshes
        // the active query once indexing completes.
        if (newBackfill != null) {
            val watcher = scope.launch(Dispatchers.Default) {
                while (!newBackfill.isFinished()) delay(backfillPollMillis)
                val refresh = synchronized(lock) { activeQuery }
                mutableState.update { it.copy(indexing = false) }
                if (refresh != null) runQuery(refresh, keepExistingHits = true)
            }
            synchronized(lock) { backfillWatcher = watcher }
        }
        runQuery(query, keepExistingHits = false)
    }

    private fun runQuery(query: MessageSearchQuery, keepExistingHits: Boolean) {
        val token = generation.incrementAndGet()
        val isIndexing: Boolean
        val previousJob: Job?
        val sdkQuery = query.sdkQuery()
        if (sdkQuery == null) {
            synchronized(lock) {
                previousJob = job
                job = null
                more = null
                isIndexing = backfill?.let { !it.isFinished() } == true
            }
            previousJob?.cancel()
            mutableState.value = MessageSearchState(query, indexing = isIndexing)
            return
        }
        val requests = Channel<Unit>(Channel.CONFLATED)
        synchronized(lock) {
            previousJob = job
            more = requests
            isIndexing = backfill?.let { !it.isFinished() } == true
            mutableState.update { current ->
                MessageSearchState(
                    query = query,
                    hits = if (keepExistingHits && current.query == query) current.hits else emptyList(),
                    loading = true,
                    endReached = false,
                    indexing = isIndexing,
                )
            }
            job = scope.launch(Dispatchers.Default) {
                // Checked inside the update, so a listener on an SDK thread can't land on a newer search's state.
                fun publish(change: (MessageSearchState) -> MessageSearchState) {
                    mutableState.update { if (generation.get() == token) change(it) else it }
                }
                val results = mutableListOf<SearchServiceResult>()
                val queryReady = AtomicBoolean(!keepExistingHits)
                var handle: TaskHandle? = null
                try {
                    client.searchService().use { service ->
                        handle = service.subscribeToResults(object : SearchServiceResultsListener {
                            override fun onUpdate(updates: List<SearchServiceResultsUpdate>) {
                                val hits = synchronized(results) {
                                    updates.forEach { results.apply(it) }
                                    results.mapNotNull { it.hit(query.roomId) }.distinctBy { it.roomId to it.eventId }
                                }
                                if (queryReady.get() || hits.isNotEmpty()) publish { it.copy(hits = hits) }
                            }
                        })
                        service.setQuery(sdkQuery)
                        // When narrowed to one conversation (`in:`), pull a few more global pages if page 1 held hits
                        // only from other rooms, so the reader sees matches immediately instead of an empty page.
                        if (query.roomId != null) {
                            var extraPages = 0
                            while (extraPages < 5) {
                                val hasMatch = synchronized(results) {
                                    results.any { it.hit(query.roomId) != null }
                                }
                                val pagination = service.paginationState()
                                val end = pagination is SearchServicePaginationState.Idle && pagination.endReached
                                if (hasMatch || end) break
                                service.paginate()
                                extraPages++
                            }
                        }
                        queryReady.set(true)
                        val finalHits = synchronized(results) {
                            results.mapNotNull { it.hit(query.roomId) }.distinctBy { it.roomId to it.eventId }
                        }
                        publish { it.copy(hits = finalHits) }
                        while (true) {
                            val pagination = service.paginationState()
                            val end = pagination is SearchServicePaginationState.Idle && pagination.endReached
                            publish { it.copy(loading = false, endReached = end) }
                            if (end) break
                            requests.receive()
                            publish { it.copy(loading = true) }
                            service.paginate()
                        }
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    publish { it.copy(loading = false, endReached = true, error = "Couldn’t search messages.") }
                } finally {
                    handle?.let { runCatching { it.cancel() }; it.close() }
                }
            }
        }
        previousJob?.cancel()
    }

    /** Asks for the next page of the current search, once the one before has arrived. */
    fun loadMore() { synchronized(lock) { more }?.trySend(Unit) }

    fun clear() {
        generation.incrementAndGet()
        val previousJob: Job?
        val isIndexing: Boolean
        synchronized(lock) {
            activeQuery = null
            previousJob = job
            job = null
            more = null
            isIndexing = backfill?.let { !it.isFinished() } == true
        }
        previousJob?.cancel()
        mutableState.value = MessageSearchState(indexing = isIndexing)
    }

    suspend fun close() = withContext(NonCancellable) {
        generation.incrementAndGet()
        val watcher: Job?
        val activeJob: Job?
        val handle: TaskHandle?
        synchronized(lock) {
            activeQuery = null
            watcher = backfillWatcher
            backfillWatcher = null
            activeJob = job
            job = null
            more = null
            handle = backfill
            backfill = null
        }
        watcher?.cancelAndJoin()
        activeJob?.cancelAndJoin()
        handle?.let { runCatching { it.cancel() }; it.close() }
    }

    private fun MutableList<SearchServiceResult>.apply(update: SearchServiceResultsUpdate) {
        when (update) {
            is SearchServiceResultsUpdate.Append -> addAll(update.values)
            is SearchServiceResultsUpdate.Clear -> clear()
            is SearchServiceResultsUpdate.PushFront -> add(0, update.value)
            is SearchServiceResultsUpdate.PushBack -> add(update.value)
            is SearchServiceResultsUpdate.PopFront -> removeFirstOrNull()
            is SearchServiceResultsUpdate.PopBack -> removeLastOrNull()
            is SearchServiceResultsUpdate.Insert -> add(update.index.toInt(), update.value)
            is SearchServiceResultsUpdate.Set -> set(update.index.toInt(), update.value)
            is SearchServiceResultsUpdate.Remove -> removeAt(update.index.toInt())
            is SearchServiceResultsUpdate.Truncate -> subList(update.length.toInt(), size).clear()
            is SearchServiceResultsUpdate.Reset -> { clear(); addAll(update.values) }
        }
    }

    /** A hit worth listing: a message with text, in the conversation the In filter names, if any. */
    private fun SearchServiceResult.hit(roomId: String?): SearchHit? {
        val message = this as? SearchServiceResult.Message ?: return null
        if (roomId != null && message.roomId != roomId) return null
        val result = message.result
        val body = previewText(result.content)?.takeIf { it.isNotBlank() } ?: return null
        val profile = result.senderProfile as? ProfileDetails.Ready
        val name = result.senderProfile.nameOf(result.sender)
        return SearchHit(message.roomId, result.eventId, result.sender, name, body, result.timestamp.toLong(), profile?.avatarUrl)
    }
}
