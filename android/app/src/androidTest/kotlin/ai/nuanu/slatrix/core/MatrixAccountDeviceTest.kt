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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.ClientDelegate
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.ClientSessionDelegate
import org.matrix.rustcomponents.sdk.HomeserverLoginDetails
import org.matrix.rustcomponents.sdk.OAuthPrompt
import org.matrix.rustcomponents.sdk.SsoHandler
import uniffi.matrix_sdk.OAuthAuthorizationData
import uniffi.matrix_sdk.NoHandle as OAuthNoHandle
import org.matrix.rustcomponents.sdk.OAuthConfiguration
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
    private val oauthConfiguration = OAuthConfiguration(
        "Slatrix", "com.github.nuanu-ai.slatrix.dev:/oauth/callback", "https://github.com/nuanu-ai/slatrix",
        null, null, null, emptyMap(),
    )

    @Before fun setUp() { check(directory.mkdirs()) }
    @After fun tearDown() {
        scope.cancel()
        store.clear()
        directory.deleteRecursively()
    }

    @Test fun homeserverDiscoveryOnlyOffersAdvertisedMethodsWithoutSigningIn() = runBlocking {
        val client = AuthClient()
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ -> client }
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
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { homeserver, _, _, _, _ ->
            assertEquals("https://matrix.example.org", homeserver)
            client
        }
        discoverServer(account, "  https://matrix.example.org/  ")
        account.signIn("  alice  ", " password ")
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
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ -> client }
        try {
            discoverServer(account)
            account.signIn("alice", "password")
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

    @Test fun lateDelegateCallbackAfterCancelCannotReplaceTheSavedSession() = runBlocking {
        val client = AuthClient()
        var delegate: ClientSessionDelegate? = null
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, persistence ->
            delegate = persistence
            client
        }
        discoverServer(account)
        account.signIn("alice", "password")
        withTimeout(5_000) { account.state.first { it is AccountState.Connected } }
        val saved = store.load()
        account.cancel()
        delegate!!.saveSessionInKeychain(client.authenticatedSession.copy(accessToken = "late-refreshed-token"))

        assertEquals(AccountState.SignedOut, account.state.value)
        assertEquals(saved, SessionStore(context).load())
    }

    @Test fun restoreReusesTheDeviceStoreAndPersistsRefreshedTokens() = runBlocking {
        val client = AuthClient()
        val saved = StoredSession(
            client.authenticatedSession, "9de7b914-3890-4354-b3bb-8f4f53f0ee63",
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
        )
        store.save(saved)
        var delegate: ClientSessionDelegate? = null
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) {
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
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, persistence ->
            delegate = persistence
            client
        }
        discoverServer(account)
        account.signIn("alice", "password")
        withTimeout(5_000) { account.state.first { it is AccountState.Connected } }
        val saved = store.load()
        val retainedDirectory = File(target.cacheDir, "${directory.name}-retained")
        check(directory.renameTo(retainedDirectory))
        try {
            check(directory.createNewFile())
            val refreshed = client.authenticatedSession.copy(accessToken = "unsaved-refreshed-token")
            delegate!!.saveSessionInKeychain(refreshed)

            val connected = account.state.value as AccountState.Connected
            assertNotNull("The account warns that its session is unsaved", connected.warning)
            assertEquals(refreshed, delegate.retrieveSessionFromKeychain(refreshed.userId))
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
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ ->
            builtClient = true
            AuthClient()
        }
        account.selectHomeserver("https://matrix.example.org")
        val failed = withTimeout(5_000) { account.state.first { it is AccountState.Failed } } as AccountState.Failed

        assertTrue(failed.canRetryRestore)
        assertFalse(builtClient)
        assertTrue(unreadable.contentEquals(sessionFile.readBytes()))
    }

    @Test fun unsafeHomeserversCannotReachTheClient() = runBlocking {
        var builtClient = false
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ ->
            builtClient = true
            AuthClient()
        }
        for (homeserver in listOf(
            "http://matrix.example.org", "https://alice:password@matrix.example.org",
            "https://matrix.example.org/?access_token=secret", "https://matrix.example.org/#secret",
        )) {
            account.selectHomeserver(homeserver)
            withTimeout(5_000) { account.state.first { it is AccountState.Failed } }
            account.cancel()
        }
        assertFalse(builtClient)
    }

    @Test fun sdkLoginErrorsDoNotExposeCredentials() = runBlocking {
        val client = AuthClient { error("password=fictional-secret; access_token=fictional-token") }
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ -> client }
        discoverServer(account)
        account.signIn("alice", "fictional-secret")
        val failed = withTimeout(5_000) { account.state.first { it is AccountState.Failed } } as AccountState.Failed

        assertEquals("Couldn’t sign in. Check your details and try again.", failed.message)
        assertFalse(failed.canRetryRestore)
        assertNull(SessionStore(context).load())
    }

    @Test fun oauthCallbackUsesTheClientThatDiscoveredTheServer() = runBlocking {
        val client = AuthClient(LoginDetails(password = true, oauth = true))
        val clients = ArrayDeque(listOf(client, AuthClient(LoginDetails(oauth = true))))
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ -> clients.removeFirst() }
        discoverServer(account)
        account.signInWithBrowser()
        val browser = withTimeout(5_000) { account.state.first { it is AccountState.BrowserSignIn } } as AccountState.BrowserSignIn
        assertEquals("https://identity.example.org/authorize?state=issued-by-sdk", browser.url)
        assertEquals(oauthConfiguration.redirectUri, client.oauthConfig?.redirectUri)
        val callback = "${oauthConfiguration.redirectUri}?code=fictional-code&state=issued-by-sdk"
        account.handleCallback(callback)
        val connected = withTimeout(5_000) { account.state.first { it is AccountState.Connected } } as AccountState.Connected

        assertEquals(client, connected.client)
        assertEquals(callback, client.oauthCallback)
        assertNull(client.credentials)
        assertEquals(client.authenticatedSession, store.load()?.session)
    }

    @Test fun oauthRejectsAChangedCallbackRouteBeforeHandingTokensToTheSdk() = runBlocking {
        val client = AuthClient(LoginDetails(oauth = true))
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ -> client }
        discoverServer(account)
        account.signInWithBrowser()
        withTimeout(5_000) { account.state.first { it is AccountState.BrowserSignIn } }
        account.handleCallback("com.github.nuanu-ai.slatrix.dev://other/oauth/callback?code=fictional-code&state=issued-by-sdk")
        withTimeout(5_000) { account.state.first { it is AccountState.Failed } }
        withTimeout(5_000) { client.abortedOauth.await() }

        assertNull(client.oauthCallback)
        assertNull(store.load())
    }

    @Test fun unsolicitedCallbackBeforeBrowserDoesNotPreventRestartingServerSelection() = runBlocking {
        val first = AuthClient()
        val clients = ArrayDeque(listOf(first, AuthClient()))
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ -> clients.removeFirst() }
        discoverServer(account)
        account.handleCallback("${oauthConfiguration.redirectUri}?code=unsolicited-code&state=unsolicited-state")
        val failure = account.state.value as AccountState.Failed
        assertNull(failure.options)

        account.selectHomeserver("https://matrix.example.org")
        withTimeout(5_000) { account.state.first { it is AccountState.ChooseMethod } }
        withTimeout(5_000) { first.closed.await() }
        assertNull(first.credentials)
        assertNull(store.load())
    }

    @Test fun legacySsoCompletesOnlyWithTheNonceIssuedForItsRedirect() = runBlocking {
        val client = AuthClient(LoginDetails(password = false, sso = true))
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ -> client }
        discoverServer(account)
        account.signInWithBrowser()
        withTimeout(5_000) { account.state.first { it is AccountState.BrowserSignIn } }
        val redirect = client.ssoRedirect!!
        assertTrue(redirect.startsWith("${oauthConfiguration.redirectUri}?state="))
        assertTrue(redirect.substringAfter("?state=").isNotEmpty())
        val callback = "$redirect&loginToken=fictional-sso-token"
        account.handleCallback(callback)
        withTimeout(5_000) { account.state.first { it is AccountState.Connected } }

        assertEquals(callback, client.ssoCallback)
        assertNull(client.credentials)
        assertEquals(client.authenticatedSession, store.load()?.session)
    }

    @Test fun legacySsoRejectsWrongAndDuplicatedStateBeforeFinishing() = runBlocking {
        for (duplicate in listOf(false, true)) {
            val client = AuthClient(LoginDetails(password = false, sso = true))
            val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ -> client }
            discoverServer(account)
            account.signInWithBrowser()
            withTimeout(5_000) { account.state.first { it is AccountState.BrowserSignIn } }
            val callback = if (duplicate) "${client.ssoRedirect}&state=wrong&loginToken=fictional-token"
                else "${oauthConfiguration.redirectUri}?state=wrong&loginToken=fictional-token"
            account.handleCallback(callback)
            withTimeout(5_000) { account.state.first { it is AccountState.Failed } }
            withTimeout(5_000) { client.closed.await() }

            assertNull(client.ssoCallback)
            assertNull(store.load())
        }
    }

    @Test fun cancellingOAuthAbortsAuthorizationAndRemovesItsUnreferencedStore() = runBlocking {
        val client = AuthClient(LoginDetails(oauth = true))
        var clientDirectory: File? = null
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, storeId, _, _, _ ->
            clientDirectory = File(directory, "matrix/$storeId").apply { mkdirs(); File(this, "keys").writeText("encrypted-fixture") }
            client
        }
        discoverServer(account)
        account.signInWithBrowser()
        withTimeout(5_000) { account.state.first { it is AccountState.BrowserSignIn } }
        account.cancel()
        withTimeout(5_000) { client.abortedOauth.await(); scope.coroutineContext[Job]!!.children.toList().joinAll() }

        assertEquals(AccountState.SignedOut, account.state.value)
        assertFalse(clientDirectory!!.exists())
        assertNull(store.load())
    }

    @Test fun cancellingKeepsAFreshStoreWhenSavedSessionOwnershipIsUncertain() = runBlocking {
        val client = AuthClient(LoginDetails(oauth = true))
        var clientDirectory: File? = null
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, storeId, _, _, _ ->
            clientDirectory = File(directory, "matrix/$storeId").apply { mkdirs(); File(this, "keys").writeText("encrypted-fixture") }
            client
        }
        discoverServer(account)
        val unreadable = "uncertain-saved-session".toByteArray()
        File(directory, "session.enc").writeBytes(unreadable)
        account.cancel()
        withTimeout(5_000) { scope.coroutineContext[Job]!!.children.toList().joinAll() }

        assertTrue(clientDirectory!!.exists())
        assertTrue(unreadable.contentEquals(File(directory, "session.enc").readBytes()))
    }

    @Test fun signingOutReturnsToSignInAtOnceAndCleansUpBehindANewSignIn() = runBlocking {
        val client = AuthClient()
        val clients = ArrayDeque(listOf(client, AuthClient()))
        val directories = mutableListOf<File>()
        var cleanedUp: Client? = null
        val releaseCleanup = CompletableDeferred<Unit>()
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration, onSignOut = {
            check(!client.loggedOut)
            cleanedUp = it
            releaseCleanup.await()
        }) { _, storeId, _, _, _ ->
            directories += File(directory, "matrix/$storeId").apply { mkdirs(); File(this, "keys").writeText("encrypted-fixture") }
            clients.removeFirst()
        }
        store.save(StoredSession(client.authenticatedSession, "9de7b914-3890-4354-b3bb-8f4f53f0ee63",
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="))
        account.restore()
        withTimeout(5_000) { account.state.first { it is AccountState.Connected } }

        account.signOut()
        withTimeout(5_000) { account.state.first { it is AccountState.SignedOut } }
        assertNull(store.load())
        discoverServer(account)
        releaseCleanup.complete(Unit)
        withTimeout(5_000) { scope.coroutineContext[Job]!!.children.toList().joinAll() }

        assertEquals("Push and notification cleanup gets the live client before logout", client, cleanedUp)
        assertTrue(client.loggedOut)
        assertTrue("The auth error subscription keeps the closed client alive", client.subscriptionCancelled)
        assertFalse(directories.first().exists())
        assertTrue("A sign-in started during cleanup keeps its store", directories.last().exists())
    }

    @Test fun aSessionThatCannotBeForgottenStaysSavedAndSignedInOnTheServer() = runBlocking {
        val client = AuthClient()
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ -> client }
        discoverServer(account)
        account.signIn("alice", "password")
        withTimeout(5_000) { account.state.first { it is AccountState.Connected } }
        val retainedDirectory = File(target.cacheDir, "${directory.name}-retained")
        check(directory.renameTo(retainedDirectory))
        try {
            check(directory.createNewFile())
            account.signOut()
            val failed = withTimeout(5_000) { account.state.first { it is AccountState.Failed } } as AccountState.Failed
            withTimeout(5_000) { scope.coroutineContext[Job]!!.children.toList().joinAll() }

            assertTrue(failed.canRetryRestore)
            assertFalse(client.loggedOut)
        } finally {
            directory.delete()
            check(retainedDirectory.renameTo(directory))
        }
        assertEquals(client.authenticatedSession, store.load()?.session)
    }

    @Test fun aRevokedSessionSignsOutWhileSoftLogoutAndStaleClientsKeepTheSession() = runBlocking {
        val revoked = AuthClient()
        val next = AuthClient()
        val clients = ArrayDeque(listOf(revoked, next))
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, _ -> clients.removeFirst() }
        discoverServer(account)
        account.signIn("alice", "password")
        withTimeout(5_000) { account.state.first { it is AccountState.Connected } }

        revoked.delegate!!.didReceiveAuthError(isSoftLogout = true)
        assertTrue(account.state.value is AccountState.Connected)
        revoked.delegate!!.didReceiveAuthError(isSoftLogout = false)
        withTimeout(5_000) { account.state.first { it is AccountState.SignedOut } }
        assertNull(store.load())

        discoverServer(account)
        account.signIn("alice", "password")
        withTimeout(5_000) { account.state.first { it is AccountState.Connected } }
        revoked.delegate!!.didReceiveAuthError(isSoftLogout = false)
        assertEquals(next, (account.state.value as AccountState.Connected).client)
        assertEquals(next.authenticatedSession, store.load()?.session)
    }

    @Test fun aTokenRefreshedWhileSignInFinishesIsTheOneSaved() = runBlocking {
        var delegate: ClientSessionDelegate? = null
        val refreshed = AuthClient().authenticatedSession.copy(accessToken = "refreshed-access", refreshToken = "refreshed-refresh")
        val client = AuthClient(beforeSession = { delegate!!.saveSessionInKeychain(refreshed) })
        val account = MatrixAccount(scope, store, File(directory, "matrix"), oauthConfiguration) { _, _, _, _, persistence ->
            delegate = persistence
            client
        }
        discoverServer(account)
        account.signIn("alice", "password")
        withTimeout(5_000) { account.state.first { it is AccountState.Connected } }

        assertEquals(refreshed, SessionStore(context).load()?.session)
    }

    private suspend fun discoverServer(account: MatrixAccount, homeserver: String = "https://matrix.example.org") {
        account.selectHomeserver(homeserver)
        withTimeout(5_000) { account.state.first { it is AccountState.ChooseMethod } }
    }

    private class LoginDetails(
        private val password: Boolean = true,
        private val sso: Boolean = false,
        private val oauth: Boolean = false,
    ) : HomeserverLoginDetails(NoHandle) {
        override fun url() = "https://matrix.example.org"
        override fun supportsPasswordLogin() = password
        override fun supportsSsoLogin() = sso
        override fun supportsOauthLogin() = oauth
    }

    private class AuthClient(
        private val details: LoginDetails = LoginDetails(),
        private val beforeSession: () -> Unit = {},
        private val beforeLogin: suspend () -> Unit = {},
    ) : Client(NoHandle) {
        val authenticatedSession = Session(
            "test-access-token", "test-refresh-token", "@alice:example.org", "ANDROID",
            "https://matrix.example.org", null, SlidingSyncVersion.NATIVE,
        )
        var credentials: Pair<String, String>? = null
        var loggedOut = false
        var delegate: ClientDelegate? = null
        var subscriptionCancelled = false
        var restoredSession: Session? = null
        var oauthConfig: OAuthConfiguration? = null
        var oauthCallback: String? = null
        var ssoRedirect: String? = null
        var ssoCallback: String? = null
        val abortedOauth = CompletableDeferred<Unit>()
        val closed = CompletableDeferred<Unit>()
        private val authorization = object : OAuthAuthorizationData(OAuthNoHandle) {
            override fun loginUrl() = "https://identity.example.org/authorize?state=issued-by-sdk"
        }
        private val handler = object : SsoHandler(NoHandle) {
            override fun url() = "https://matrix.example.org/_matrix/client/v3/login/sso/redirect"
            override suspend fun finish(callbackUrl: String) { ssoCallback = callbackUrl }
        }

        override suspend fun urlForOauth(
            oauthConfiguration: OAuthConfiguration, prompt: OAuthPrompt?, loginHint: String?,
            deviceId: String?, additionalScopes: List<String>?,
        ): OAuthAuthorizationData {
            oauthConfig = oauthConfiguration
            return authorization
        }
        override suspend fun loginWithOauthCallback(callbackUrl: String) { oauthCallback = callbackUrl }
        override suspend fun abortOauthAuth(authorizationData: OAuthAuthorizationData) { abortedOauth.complete(Unit) }
        override suspend fun startSsoLogin(redirectUrl: String, idpId: String?): SsoHandler {
            ssoRedirect = redirectUrl
            return handler
        }
        override fun close() { super.close(); closed.complete(Unit) }

        override suspend fun login(username: String, password: String, initialDeviceName: String?, deviceId: String?) {
            beforeLogin()
            credentials = username to password
        }
        override suspend fun homeserverLoginDetails(): HomeserverLoginDetails = details
        override suspend fun restoreSession(session: Session) { restoredSession = session }
        override fun session(): Session {
            val current = authenticatedSession
            beforeSession()
            return current
        }
        override suspend fun logout() { loggedOut = true }
        override fun setDelegate(delegate: ClientDelegate?): TaskHandle {
            this.delegate = delegate
            return object : TaskHandle(NoHandle) { override fun cancel() { subscriptionCancelled = true } }
        }
    }
}
