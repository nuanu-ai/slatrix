package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
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

        assertEquals("+(budget) +sender:\"@sam:example.org\"", service.query.await())
        assertEquals(listOf("Ship the budget", "Budget review"), found.hits.map { it.body })
        assertEquals("Sam", found.hits.first().senderName)
        assertTrue("A search indexes older history too", client.backfill.isCompleted)
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

private class SearchClient : Client(NoHandle) {
    val services = ArrayDeque<SearchService>()
    val backfill = CompletableDeferred<SearchBackfillStrategy>()
    override fun searchService(): SearchService = services.removeFirst()
    override fun runSearchBackfill(strategy: SearchBackfillStrategy): TaskHandle {
        backfill.complete(strategy)
        return object : TaskHandle(NoHandle) {
            override fun cancel() = Unit
        }
    }
}

private class SearchFake(private val hold: CompletableDeferred<Unit>? = null, private val fail: Boolean = false,
    private val results: () -> List<SearchServiceResult>) : SearchService(NoHandle) {
    val query = CompletableDeferred<String>()
    val emitted = CompletableDeferred<Unit>()
    private var listener: SearchServiceResultsListener? = null
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
    override fun paginationState(): SearchServicePaginationState = SearchServicePaginationState.Idle(endReached = true)
    override suspend fun setQuery(query: String) {
        this.query.complete(query)
        if (fail) throw IllegalStateException("Index busy")
        hold?.await()
        listener?.onUpdate(listOf(SearchServiceResultsUpdate.Reset(results())))
        emitted.complete(Unit)
    }
}

private fun hit(room: String, event: String, body: String) = SearchServiceResult.Message(room, MessageSearchResult(
    eventId = event, sender = "@sam:example.org", senderProfile = ProfileDetails.Ready("Sam", false, null, null, null),
    content = TimelineItemContent.MsgLike(MsgLikeContent(
        MsgLikeKind.Message(MessageContent(MessageType.Text(TextMessageContent(body, null)), body, false, null)), null, null, null)),
    timestamp = 1_000u,
))
