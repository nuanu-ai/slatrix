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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.ClientSessionDelegate
import org.matrix.rustcomponents.sdk.HomeserverLoginDetails
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

    @Test fun homeserverDiscoveryOnlyOffersAdvertisedMethodsWithoutSigningIn() = runBlocking {
        val client = AuthClient()
        val account = MatrixAccount(scope, store, File(directory, "matrix")) { _, _, _, _, _ -> client }
        account.selectHomeserver("https://matrix.example.org")
        val method = withTimeout(5_000) {
            account.state.first { it is AccountState.ChooseMethod }
        } as AccountState.ChooseMethod

        assertEquals(SignInOptions("https://matrix.example.org", password = true, sso = false, oauth = false), method.options)
        assertNull(client.credentials)
        assertNull(store.load())
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

    @Test fun restoreReusesTheDeviceStoreAndPersistsRefreshedTokens() = runBlocking {
        val client = AuthClient()
        val saved = StoredSession(
            client.authenticatedSession, "9de7b914-3890-4354-b3bb-8f4f53f0ee63",
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
        )
        store.save(saved)
        var delegate: ClientSessionDelegate? = null
        val account = MatrixAccount(scope, store, File(directory, "matrix")) {
                homeserver, storeId, storeKey, restoring, persistence ->
            assertEquals("https://matrix.example.org", homeserver)
            assertEquals(saved.storeId, storeId)
            assertEquals(saved.storeKey, storeKey)
            assertTrue(restoring)
            delegate = persistence
            client
        }
        account.restore()
        withTimeout(5_000) { account.state.first { it is AccountState.Connected } }
        assertEquals(saved.session, client.restoredSession)

        val refreshed = saved.session.copy(accessToken = "refreshed-access", refreshToken = "refreshed-refresh")
        delegate!!.saveSessionInKeychain(refreshed)
        assertEquals(saved.copy(session = refreshed), SessionStore(context).load())
    }

    @Test fun refreshSaveFailureRetainsTheLiveSessionAndItsLastSavedSnapshot() = runBlocking {
        val client = AuthClient()
        var delegate: ClientSessionDelegate? = null
        val account = MatrixAccount(scope, store, File(directory, "matrix")) { _, _, _, _, persistence ->
            delegate = persistence
            client
        }
        account.signIn("https://matrix.example.org", "alice", "password")
        withTimeout(5_000) { account.state.first { it is AccountState.Connected } }
        val saved = store.load()
        val retainedDirectory = File(target.cacheDir, "${directory.name}-retained")
        check(directory.renameTo(retainedDirectory))
        try {
            check(directory.createNewFile())
            val refreshed = client.authenticatedSession.copy(accessToken = "unsaved-refreshed-token")
            delegate!!.saveSessionInKeychain(refreshed)

            val connected = account.state.value as AccountState.Connected
            assertEquals("Couldn’t save your session. Keep Slatrix open.", connected.warning)
            assertEquals(refreshed, delegate!!.retrieveSessionFromKeychain(refreshed.userId))
        } finally {
            directory.delete()
            check(retainedDirectory.renameTo(directory))
        }
        assertEquals(saved, SessionStore(context).load())
    }

    @Test fun unreadableSavedSessionBlocksSignInWithoutReplacingItsBytes() = runBlocking {
        val sessionFile = File(directory, "session.enc")
        val unreadable = "unreadable-session-fixture".toByteArray()
        sessionFile.writeBytes(unreadable)
        var builtClient = false
        val account = MatrixAccount(scope, store, File(directory, "matrix")) { _, _, _, _, _ ->
            builtClient = true
            AuthClient()
        }
        account.signIn("https://matrix.example.org", "alice", "password")
        val failed = withTimeout(5_000) { account.state.first { it is AccountState.Failed } } as AccountState.Failed

        assertTrue(failed.canRetryRestore)
        assertFalse(builtClient)
        assertTrue(unreadable.contentEquals(sessionFile.readBytes()))
    }

    @Test fun unsafeHomeserversCannotReachTheClient() = runBlocking {
        var builtClient = false
        val account = MatrixAccount(scope, store, File(directory, "matrix")) { _, _, _, _, _ ->
            builtClient = true
            AuthClient()
        }
        for (homeserver in listOf(
            "http://matrix.example.org", "https://alice:password@matrix.example.org",
            "https://matrix.example.org/?access_token=secret", "https://matrix.example.org/#secret",
        )) {
            account.signIn(homeserver, "alice", "password")
            withTimeout(5_000) { account.state.first { it is AccountState.Failed } }
            account.cancel()
        }
        assertFalse(builtClient)
    }

    @Test fun sdkLoginErrorsDoNotExposeCredentials() = runBlocking {
        val client = AuthClient { error("password=fictional-secret; access_token=fictional-token") }
        val account = MatrixAccount(scope, store, File(directory, "matrix")) { _, _, _, _, _ -> client }
        account.signIn("https://matrix.example.org", "alice", "fictional-secret")
        val failed = withTimeout(5_000) { account.state.first { it is AccountState.Failed } } as AccountState.Failed

        assertEquals("Couldn’t sign in. Check your details and try again.", failed.message)
        assertFalse(failed.canRetryRestore)
        assertNull(SessionStore(context).load())
    }

    private class LoginDetails : HomeserverLoginDetails(NoHandle) {
        override fun url() = "https://matrix.example.org"
        override fun supportsPasswordLogin() = true
        override fun supportsSsoLogin() = false
        override fun supportsOauthLogin() = false
    }

    private class AuthClient(private val beforeLogin: suspend () -> Unit = {}) : Client(NoHandle) {
        val authenticatedSession = Session(
            "test-access-token", "test-refresh-token", "@alice:example.org", "ANDROID",
            "https://matrix.example.org", null, SlidingSyncVersion.NATIVE,
        )
        var credentials: Pair<String, String>? = null
        var restoredSession: Session? = null

        override suspend fun login(username: String, password: String, initialDeviceName: String?, deviceId: String?) {
            beforeLogin()
            credentials = username to password
        }
        override suspend fun homeserverLoginDetails(): HomeserverLoginDetails = LoginDetails()
        override suspend fun restoreSession(session: Session) { restoredSession = session }
        override fun session() = authenticatedSession
    }
}
