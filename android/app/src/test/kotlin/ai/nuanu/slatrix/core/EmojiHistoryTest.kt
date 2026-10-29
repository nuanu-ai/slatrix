package ai.nuanu.slatrix.core

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.RecentEmoji

class EmojiHistoryTest {
    // capability: message.react.quick
    @Test fun anEmojiUsedBeforeTheAccountsListArrivesStaysFirstAndIsSaved() = runTest {
        val client = RecentClient()
        val recent = EmojiHistory(backgroundScope, client)
        runCurrent()
        recent.use("🚀")
        assertEquals(listOf("🚀"), recent.state.value)
        client.stored.complete(listOf(RecentEmoji("🎉", 3u), RecentEmoji("🚀", 1u)))
        assertEquals(listOf("🚀", "🎉"), recent.state.first { it.size == 2 })
        assertEquals("🚀", client.added.receive())
    }
}

private class RecentClient : Client(NoHandle) {
    val stored = CompletableDeferred<List<RecentEmoji>>()
    val added = Channel<String>(Channel.UNLIMITED)
    override suspend fun getRecentEmojis(): List<RecentEmoji> = stored.await()
    override suspend fun addRecentEmoji(emoji: String) { added.send(emoji) }
}
