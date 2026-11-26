package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.matrix.rustcomponents.sdk.*
import uniffi.matrix_sdk.SearchBackfillStrategy
import uniffi.matrix_sdk_ui.SearchServicePaginationState

class MatrixSearchTest {
    // capability: search.messages
    @Test fun aSearchListsTheIndexsHitsForTheQueryItAsks() = runTest {
        val client = SearchClient()
        val search = MatrixSearch(backgroundScope, client)
        val service = SearchFake { listOf(hit("!a:example.org", "\$1", "Ship the budget"), hit("!b:example.org", "\$2", "Budget review")) }
        client.services += service

        search.search(MessageSearchQuery("budget", senderId = "@sam:example.org"))
        val found = search.state.first { it.hits.size == 2 && !it.loading }

        assertEquals(
            "+(body:budget^2 OR body:[budget TO budget\uff5a]) +sender:\"@sam:example.org\"",
            service.query.await())
        assertEquals(listOf("Ship the budget", "Budget review"), found.hits.map { it.body })
        assertEquals("Sam", found.hits.first().senderName)
        assertTrue("A search indexes older history too", client.backfill.isCompleted)
        search.close()
    }

    // capability: search.messages
    @Test fun finishingBackfillRefreshesTheActiveSearch() = runTest {
        val client = SearchClient(backfillFinished = false)
        val search = MatrixSearch(backgroundScope, client, backfillPollMillis = 10L)
        client.services += SearchFake { emptyList() }
        client.services += SearchFake { listOf(hit("!a:example.org", "\$1", "Инструменты для рассылок")) }

        search.search(MessageSearchQuery("рассыл"))
        val initial = search.state.first { !it.loading }
        assertTrue(initial.hits.isEmpty())
        assertTrue(initial.indexing)

        client.backfillFinished = true
        val refreshed = search.state.first { !it.indexing && it.hits.size == 1 }
        assertEquals(listOf("Инструменты для рассылок"), refreshed.hits.map { it.body })
        search.close()
    }

    @Test fun anInFilterKeepsOnlyThatConversationsHits() = runTest {
        val client = SearchClient()
        val search = MatrixSearch(backgroundScope, client)
        client.services += SearchFake { listOf(hit("!a:example.org", "\$1", "Ship the budget"), hit("!b:example.org", "\$2", "Budget review")) }

        search.search(MessageSearchQuery("budget", roomId = "!b:example.org"))
        assertEquals(listOf("Budget review"), search.state.first { it.hits.isNotEmpty() && !it.loading }.hits.map { it.body })
        search.close()
    }

    @Test fun anInFilterAutoPaginatesPastOtherRoomsHits() = runTest {
        val client = SearchClient()
        val search = MatrixSearch(backgroundScope, client)
        client.services += SearchFake(
            pages = listOf(
                listOf(hit("!a:example.org", "\$1", "Budget in A")),
                listOf(hit("!b:example.org", "\$2", "Budget in B")),
            ),
        )

        search.search(MessageSearchQuery("budget", roomId = "!b:example.org"))
        val found = search.state.first { !it.loading && it.hits.isNotEmpty() }
        assertEquals(listOf("Budget in B"), found.hits.map { it.body })
        search.close()
    }

    @Test fun aNewSearchIgnoresTheLateHitsOfTheOneBefore() = runTest {
        val client = SearchClient()
        val search = MatrixSearch(backgroundScope, client)
        val stale = CompletableDeferred<Unit>()
        val old = SearchFake(hold = stale) { listOf(hit("!a:example.org", "\$1", "Old plan")) }
        client.services += old
        client.services += SearchFake { listOf(hit("!a:example.org", "\$2", "New plan")) }

        search.search(MessageSearchQuery("old"))
        old.query.await()
        search.search(MessageSearchQuery("new"))
        search.state.first { state -> state.hits.any { it.body == "New plan" } }
        stale.complete(Unit)
        old.emitted.await()

        assertEquals(listOf("New plan"), search.state.value.hits.map { it.body })
        assertEquals(MessageSearchQuery("new"), search.state.value.query)
        search.close()
    }

    @Test fun aSearchThatFailsSaysSo() = runTest {
        val client = SearchClient()
        val search = MatrixSearch(backgroundScope, client)
        client.services += SearchFake(fail = true) { emptyList() }

        search.search(MessageSearchQuery("budget"))
        assertEquals("Couldn’t search messages.", search.state.first { it.error != null }.error)
        search.close()
    }
}

private class SearchClient(@Volatile var backfillFinished: Boolean = true) : Client(NoHandle) {
    val services = ArrayDeque<SearchService>()
    val backfill = CompletableDeferred<SearchBackfillStrategy>()
    override fun searchService(): SearchService = services.removeFirst()
    override fun runSearchBackfill(strategy: SearchBackfillStrategy): TaskHandle {
        backfill.complete(strategy)
        return object : TaskHandle(NoHandle) {
            override fun cancel() = Unit
            override fun isFinished(): Boolean = backfillFinished
        }
    }
}

private class SearchFake(private val hold: CompletableDeferred<Unit>? = null, private val fail: Boolean = false,
    private val pages: List<List<SearchServiceResult>>? = null,
    private val results: () -> List<SearchServiceResult> = { emptyList() }) : SearchService(NoHandle) {
    val query = CompletableDeferred<String>()
    val emitted = CompletableDeferred<Unit>()
    private var listener: SearchServiceResultsListener? = null
    private var pageIndex = 0
    override suspend fun subscribeToResults(listener: SearchServiceResultsListener): TaskHandle {
        this.listener = listener
        return object : TaskHandle(NoHandle) {
            override fun cancel() = Unit
        }
    }
    override fun subscribeToPaginationStateUpdates(listener: SearchServicePaginationStateListener): TaskHandle =
        object : TaskHandle(NoHandle) {
            override fun cancel() = Unit
        }
    override fun paginationState(): SearchServicePaginationState =
        SearchServicePaginationState.Idle(endReached = pages == null || pageIndex >= pages.size)
    override suspend fun setQuery(query: String) {
        this.query.complete(query)
        if (fail) throw IllegalStateException("Index busy")
        // An FFI call runs on after its coroutine is cancelled, and its listener still fires.
        hold?.let { withContext(NonCancellable) { it.await() } }
        val first = if (pages != null) { pageIndex = 1; pages.firstOrNull().orEmpty() } else results()
        listener?.onUpdate(listOf(SearchServiceResultsUpdate.Reset(first)))
        emitted.complete(Unit)
    }
    override suspend fun paginate() {
        val next = pages?.getOrNull(pageIndex) ?: return
        pageIndex++
        listener?.onUpdate(listOf(SearchServiceResultsUpdate.Append(next)))
    }
}

private fun hit(room: String, event: String, body: String) = SearchServiceResult.Message(room, MessageSearchResult(
    eventId = event, sender = "@sam:example.org", senderProfile = ProfileDetails.Ready("Sam", false, null, null, null),
    content = TimelineItemContent.MsgLike(MsgLikeContent(
        MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent(body, null)), body, false, null)), null, null, null)),
    timestamp = 1_000u,
))
