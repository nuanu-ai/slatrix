package ai.nuanu.slatrix.core

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.Session
import org.matrix.rustcomponents.sdk.SlidingSyncVersion

@RunWith(AndroidJUnit4::class)
class MatrixAccountDeviceTest {
    private val target = InstrumentationRegistry.getInstrumentation().targetContext
    private val directory = File(target.cacheDir, "auth-test-${UUID.randomUUID()}")
    private val context = object : ContextWrapper(target) {
        override fun getNoBackupFilesDir(): File = directory
        override fun getPackageName(): String = "${target.packageName}.${directory.name}"
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val store = SessionStore(context)

    @Before fun setUp() { check(directory.mkdirs()) }
    @After fun tearDown() {
        scope.cancel()
        store.clear()
        directory.deleteRecursively()
    }

    @Test fun signInPersistsTheAuthenticatedDeviceAndPreservesPasswordWhitespace() = runBlocking {
        val client = AuthClient()
        val account = MatrixAccount(scope, store, File(directory, "matrix")) { homeserver, _, _, _, _ ->
            assertEquals("https://matrix.example.org", homeserver)
            client
        }
        account.signIn("  https://matrix.example.org/  ", "  alice  ", " password ")
        val connected = withTimeout(5_000) { account.state.first { it is AccountState.Connected } }
        assertEquals("@alice:example.org", (connected as AccountState.Connected).userId)
        assertEquals("alice" to " password ", client.credentials)
        assertEquals(client.authenticatedSession, SessionStore(context).load()?.session)
    }

    @Test fun cancelledSignInCannotPublishOrSaveALateSdkCompletion() = runBlocking {
        val enteredLogin = CompletableDeferred<Unit>()
        val releaseLogin = CompletableDeferred<Unit>()
        val client = AuthClient {
            withContext(NonCancellable) {
                enteredLogin.complete(Unit)
                releaseLogin.await()
            }
        }
        val account = MatrixAccount(scope, store, File(directory, "matrix")) { _, _, _, _, _ -> client }
        try {
            account.signIn("https://matrix.example.org", "alice", "password")
            withTimeout(5_000) { enteredLogin.await() }
            val pendingAuthentication = scope.coroutineContext[Job]!!.children.toList()
            account.cancel()
            releaseLogin.complete(Unit)
            withTimeout(5_000) { pendingAuthentication.joinAll() }

            assertEquals(AccountState.SignedOut, account.state.value)
            assertNull(SessionStore(context).load())
        } finally {
            releaseLogin.complete(Unit)
        }
    }

    private class AuthClient(private val beforeLogin: suspend () -> Unit = {}) : Client(NoHandle) {
        val authenticatedSession = Session(
            "test-access-token", "test-refresh-token", "@alice:example.org", "ANDROID",
            "https://matrix.example.org", null, SlidingSyncVersion.NATIVE,
        )
        var credentials: Pair<String, String>? = null

        override suspend fun login(username: String, password: String, initialDeviceName: String?, deviceId: String?) {
            beforeLogin()
            credentials = username to password
        }
        override fun session() = authenticatedSession
    }
}
