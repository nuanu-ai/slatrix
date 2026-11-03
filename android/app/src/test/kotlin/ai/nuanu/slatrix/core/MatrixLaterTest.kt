package ai.nuanu.slatrix.core

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.google.gson.JsonParser
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.ClientException
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.RawAccountDataListener
import org.matrix.rustcomponents.sdk.TaskHandle
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

private const val ONE = """{"room_id":"!design:example.org","event_id":"${'$'}one","ts":1761955200000}"""
private const val THREE = """{"room_id":"!general:example.org","event_id":"${'$'}three","ts":1761955400000}"""
private const val ONE_REMOVED = """{"room_id":"!design:example.org","event_id":"${'$'}one","ts":1761955500000}"""

/** Later kept in step with the account's data, against an SDK fake, as on the Mac. */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class MatrixLaterTest {
    private val context = ApplicationProvider.getApplicationContext<Application>()
    private val online = MutableStateFlow(true)

    private fun TestScope.later(client: LaterClient) = MatrixLater(backgroundScope, client, SavedMessageStore(context, "@alex:example.org"),
        online, StandardTestDispatcher(testScheduler)).also { runCurrent() }
    private fun kept() = SavedMessageStore(context, "@alex:example.org").list.saved.map { it.eventId }

    // capability: message.save.sync
    @Test fun savesAndRemovalsMadeOnAnotherDeviceShowInLaterAfterTheirSync() = runTest {
        val client = LaterClient("""{"saved":[$ONE],"removed":[]}""")
        val later = later(client)
        assertEquals(listOf("\$one"), later.list.value.saved.map { it.eventId })

        client.sync("""{"saved":[$THREE,$ONE],"removed":[]}""")
        runCurrent()
        assertEquals(listOf("\$three", "\$one"), later.list.value.saved.map { it.eventId })
        client.sync("""{"saved":[$THREE],"removed":[$ONE_REMOVED]}""")
        runCurrent()
        assertEquals(listOf("\$three"), later.list.value.saved.map { it.eventId })
        assertEquals("What a sync brings stays on the device", listOf("\$three"), kept())
    }

    @Test fun aFirstRunPutsTheListThisDeviceKeptIntoTheAccount() = runTest {
        // As this app kept Later before it synced: the Mac's vault format, savedAt in seconds since 2001.
        context.getSharedPreferences("saved-messages", 0).edit()
            .putString("@alex:example.org", """[{"roomID":"!design:example.org","eventID":"${'$'}one","savedAt":783648000}]""").commit()
        val client = LaterClient(null)
        later(client)
        assertEquals(JSONObject("""{"saved":[$ONE],"removed":[]}""").toString(), client.server?.let { JSONObject(it).toString() })
        val shared = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/saved-messages.json").readText()).asJsonObject
        assertEquals(setOf(shared["eventType"].asString), client.types.toSet())
    }

    @Test fun signingInAgainNeverWritesTheDevicesOldListOverWhatTheAccountHolds() = runTest {
        SavedMessageStore(context, "@alex:example.org").save(SavedList(listOf(SavedMessage("!design:example.org", "\$one", 1_761_955_200_000))))
        val client = LaterClient("""{"saved":[$THREE],"removed":[$ONE_REMOVED]}""")
        val later = later(client)
        assertEquals(listOf("\$three"), later.list.value.saved.map { it.eventId })
        assertEquals(listOf("\$three"), client.savedIds())
    }

    @Test fun aSaveAfterTheAccountCouldntBeReadReadsItAgainAndReachesIt() = runTest {
        val client = LaterClient("""{"saved":[$THREE],"removed":[]}""")
        client.failsReads = true
        val later = later(client)
        client.failsReads = false
        later.set("!general:example.org", "\$two", saved = true, now = 1_761_955_300_000)
        runCurrent()
        assertEquals(listOf("\$three", "\$two"), client.savedIds())
    }

    @Test fun aSaveMadeOfflineStaysAndReachesTheAccountOnceTheConnectionIsBack() = runTest {
        val client = LaterClient("""{"saved":[$ONE],"removed":[]}""")
        val later = later(client)
        client.failsWrites = true
        later.set("!general:example.org", "\$two", saved = true, now = 1_761_955_300_000)
        runCurrent()
        assertEquals(listOf("\$two", "\$one"), kept())
        online.value = false
        runCurrent()
        client.land("""{"saved":[$THREE,$ONE],"removed":[]}""")

        client.failsWrites = false
        online.value = true
        runCurrent()
        assertEquals(listOf("\$three", "\$two", "\$one"), client.savedIds())
    }

    @Test fun aClosedLaterNeverWritesOverTheOneThatReplacedIt() = runTest {
        val client = LaterClient("""{"saved":[$ONE],"removed":[]}""")
        val held = CompletableDeferred<Unit>()
        client.read = held
        later(client).close()
        client.read = null
        later(client).set("!general:example.org", "\$two", saved = true, now = 1_761_955_300_000)
        runCurrent()

        // The first one's read of the account answers only now.
        held.complete(Unit)
        runCurrent()
        assertEquals(listOf("\$two", "\$one"), kept())
    }

    @Test fun aSaveHereOutlastsAnotherDevicesListThatLandsWhileThisOnesWriteWaitsForItsReply() = runTest {
        val client = LaterClient("""{"saved":[$ONE],"removed":[]}""")
        val later = later(client)
        val reply = CompletableDeferred<Unit>()
        client.reply = reply
        later.set("!general:example.org", "\$two", saved = true, now = 1_761_955_300_000)
        runCurrent()
        assertEquals(listOf("\$two", "\$one"), client.savedIds())

        // Written by a device that hadn't seen $two yet, after this one's write landed.
        client.sync("""{"saved":[$ONE],"removed":[]}""")
        runCurrent()
        reply.complete(Unit)
        runCurrent()
        assertEquals(listOf("\$two", "\$one"), client.savedIds())
    }
}

/** One account's Later on the server, as this device's SDK reads, hears and writes it. */
private class LaterClient(server: String?) : Client(NoHandle) {
    /** What the account holds: the last write to land, or the last list a sync brought. */
    var server: String? = server
        private set
    var failsWrites = false
    var failsReads = false
    /** Holds a write's reply after it lands, until the test completes it. */
    var reply: CompletableDeferred<Unit>? = null
    /** Holds a read's answer, until the test completes it. */
    var read: CompletableDeferred<Unit>? = null
    val types = mutableListOf<String>()
    private val listeners = mutableListOf<RawAccountDataListener>()

    /** The device's store before its first sync, as after signing in: nothing it can trust yet, so Later never reads it. */
    override suspend fun accountData(eventType: String): String? = null
    override suspend fun fetchAccountData(eventType: String): String? {
        types += eventType
        if (failsReads) throw ClientException.Generic("fixture can't reach the server", null)
        // The answer is what the account held when asked, however late it arrives.
        val answer = server
        read?.await()
        return answer
    }
    override fun observeRawAccountDataEvent(eventType: String, listener: RawAccountDataListener): TaskHandle {
        types += eventType
        listeners += listener
        return object : TaskHandle(NoHandle) { override fun cancel() = Unit }
    }
    override suspend fun setAccountData(eventType: String, content: String) {
        types += eventType
        if (failsWrites) throw ClientException.Generic("fixture is offline", null)
        server = content
        reply?.await()
    }
    /** Another device's write, which this device doesn't hear while it's offline. */
    fun land(content: String) { server = content }
    /** A sync bringing what another device wrote. */
    fun sync(content: String) {
        server = content
        listeners.forEach { it.onChange(content) }
    }
    fun savedIds() = server?.let { JSONObject(it).getJSONArray("saved") }?.let { saved -> List(saved.length()) { saved.getJSONObject(it).getString("event_id") } }
}
