package ai.nuanu.slatrix.core

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.Session
import org.matrix.rustcomponents.sdk.SlidingSyncVersion

@RunWith(AndroidJUnit4::class)
class MatrixAccountDeviceTest {
    @Test fun signInPersistsTheAuthenticatedDeviceAndPreservesPasswordWhitespace() = runBlocking {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(target.cacheDir, "auth-test-${UUID.randomUUID()}").apply { mkdirs() }
        val context = object : ContextWrapper(target) {
            override fun getNoBackupFilesDir(): File = directory
            override fun getPackageName(): String = "${target.packageName}.${directory.name}"
        }
        val store = SessionStore(context)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val client = AuthClient()
        val account = MatrixAccount(scope, store, File(context.noBackupFilesDir, "matrix")) {
                homeserver, _, _, _, _ ->
            assertEquals("https://matrix.example.org", homeserver)
            client
        }
        try {
            account.signIn("  https://matrix.example.org/  ", "  alice  ", " password ")
            val connected = withTimeout(5_000) { account.state.first { it is AccountState.Connected } }
            assertEquals("@alice:example.org", (connected as AccountState.Connected).userId)
            assertEquals("alice" to " password ", client.credentials)
            assertEquals(client.authenticatedSession, SessionStore(context).load()?.session)
        } finally {
            scope.cancel()
            store.clear()
            directory.deleteRecursively()
        }
    }

    private class AuthClient : Client(NoHandle) {
        val authenticatedSession = Session(
            "test-access-token", "test-refresh-token", "@alice:example.org", "ANDROID",
            "https://matrix.example.org", null, SlidingSyncVersion.NATIVE,
        )
        var credentials: Pair<String, String>? = null

        override suspend fun login(username: String, password: String, initialDeviceName: String?, deviceId: String?) {
            credentials = username to password
        }
        override fun session() = authenticatedSession
    }
}
