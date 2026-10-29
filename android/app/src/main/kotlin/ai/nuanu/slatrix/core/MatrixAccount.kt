package ai.nuanu.slatrix.core

import android.util.Base64
import java.io.File
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.ClientBuilder
import org.matrix.rustcomponents.sdk.ClientException
import org.matrix.rustcomponents.sdk.ClientSessionDelegate
import org.matrix.rustcomponents.sdk.OAuthConfiguration
import org.matrix.rustcomponents.sdk.Session
import org.matrix.rustcomponents.sdk.SlidingSyncVersionBuilder
import org.matrix.rustcomponents.sdk.SqliteStoreBuilder
import org.matrix.rustcomponents.sdk.SsoHandler
import uniffi.matrix_sdk.OAuthAuthorizationData

data class SignInOptions(val homeserver: String, val password: Boolean, val sso: Boolean, val oauth: Boolean)

sealed interface AccountState {
    data object SignedOut : AccountState
    data class Connecting(val restoring: Boolean = false, val options: SignInOptions? = null) : AccountState
    data class ChooseMethod(val options: SignInOptions) : AccountState
    data class BrowserSignIn(val url: String, val options: SignInOptions, val attemptId: String) : AccountState {
        override fun toString() = "BrowserSignIn(redacted)"
    }
    data class Connected(val client: Client, val userId: String, val warning: String? = null) : AccountState
    data class Failed(val message: String, val canRetryRestore: Boolean, val options: SignInOptions? = null) : AccountState
}

class MatrixAccount(
    private val scope: CoroutineScope,
    private val store: SessionStore,
    private val rootDirectory: File,
    private val oauthConfiguration: OAuthConfiguration,
    private val clientFactory: suspend (String, String, String, Boolean, ClientSessionDelegate) -> Client =
        { homeserver, storeId, storeKey, restoring, delegate ->
            val directory = File(rootDirectory, storeId)
            val data = File(directory, "data").apply { check(isDirectory || mkdirs()) }
            val cache = File(directory, "cache").apply { check(isDirectory || mkdirs()) }
            val search = File(directory, "search").apply { check(isDirectory || mkdirs()) }
            val builder = if (restoring) {
                ClientBuilder().homeserverUrl(homeserver).slidingSyncVersionBuilder(SlidingSyncVersionBuilder.NATIVE)
            } else {
                ClientBuilder().serverNameOrHomeserverUrl(homeserver)
                    .slidingSyncVersionBuilder(SlidingSyncVersionBuilder.DISCOVER_NATIVE)
            }
            builder.sqliteStore(SqliteStoreBuilder(data.path, cache.path).key(Base64.decode(storeKey, Base64.NO_WRAP)))
                .withSearchIndexStore(search.path, storeKey)
                .enableAutomaticBackPagination(true)
                .setSessionDelegate(delegate)
                .threadsEnabled(true, false)
                .build()
        },
) {
    private val lock = Any()
    private val mutableState = MutableStateFlow<AccountState>(AccountState.SignedOut)
    val state: StateFlow<AccountState> = mutableState.asStateFlow()
    private var generation = 0L
    private var operation: Job? = null
    private var operationSerial = 0L
    private var pending: Attempt? = null
    private var connected: Attempt? = null
    private var options: SignInOptions? = null

    init { scope.coroutineContext[Job]?.invokeOnCompletion { cancel() } }

    fun selectHomeserver(server: String) {
        synchronized(lock) {
            if (operation?.isActive == true || connected != null || pending != null) return
        }
        runOperation {
            val homeserver = validatedHomeserver(server)
            val attempt = freshAttempt(it, homeserver)
            val discovered = attempt.client.homeserverLoginDetails().use { details ->
                val resolvedServer = validatedHomeserver(details.url())
                SignInOptions(resolvedServer, details.supportsPasswordLogin(), details.supportsSsoLogin(), details.supportsOauthLogin())
            }
            checkOwner(it)
            require(discovered.password || discovered.sso || discovered.oauth)
            synchronized(lock) {
                checkOwner(it)
                options = discovered
                operation = null
                mutableState.value = AccountState.ChooseMethod(discovered)
            }
        }
    }

    fun signIn(username: String, password: String) {
        val selected = synchronized(lock) { options } ?: return
        runOperation {
            require(selected == synchronized(lock) { options })
            require(selected.password && !selected.oauth && username.trim().isNotEmpty() && password.isNotEmpty())
            val attempt = freshAttempt(it, selected.homeserver)
            attempt.client.login(username.trim(), password, "Slatrix · Android", null)
            finish(attempt)
        }
    }

    fun signInWithBrowser() {
        val selected = synchronized(lock) { options } ?: return
        runOperation {
            require(selected == synchronized(lock) { options })
            require(selected.oauth || selected.sso)
            val attempt = freshAttempt(it, selected.homeserver)
            val redirect = callbackRoute()
            val url = if (selected.oauth) {
                val authorization = attempt.client.urlForOauth(oauthConfiguration, null, null, null, null)
                attempt.oauth = authorization
                authorization.loginUrl()
            } else {
                val nonce = Base64.encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) }, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
                attempt.nonce = nonce
                val handler = attempt.client.startSsoLogin("$redirect?state=$nonce", null)
                attempt.sso = handler
                handler.url()
            }
            val browser = URI(url)
            require(browser.scheme == "https" && !browser.host.isNullOrEmpty() && browser.rawUserInfo == null)
            synchronized(lock) {
                checkOwner(it)
                operation = null
                mutableState.value = AccountState.BrowserSignIn(url, selected, attempt.storeId)
            }
        }
    }

    fun handleCallback(url: String) {
        val attempt = synchronized(lock) {
            pending?.takeIf { mutableState.value is AccountState.BrowserSignIn }
        }
        if (attempt == null) {
            synchronized(lock) {
                if (connected == null && operation?.isActive != true) {
                    mutableState.value = AccountState.Failed("Sign-in expired. Choose your server and try again.", false)
                }
            }
            return
        }
        runOperation {
            checkOwner(attempt.owner)
            require(validCallbackRoute(url))
            if (attempt.oauth != null) {
                attempt.client.loginWithOauthCallback(url)
                attempt.oauth?.close()
                attempt.oauth = null
            } else {
                val nonce = attempt.nonce ?: error("No pending sign-in")
                val states = URI(url).rawQuery.orEmpty().split('&').map { field ->
                    val pair = field.split('=', limit = 2)
                    URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8")
                }.filter { it.first == "state" }
                require(states.size == 1 && MessageDigest.isEqual(states.single().second.toByteArray(), nonce.toByteArray()))
                attempt.sso!!.finish(url)
                attempt.sso?.close()
                attempt.sso = null
                attempt.nonce = null
            }
            finish(attempt)
        }
    }

    fun restore() = runOperation(restoring = true) { owner ->
        val saved = store.load()
        checkOwner(owner)
        if (saved == null) {
            synchronized(lock) { checkOwner(owner); operation = null; mutableState.value = AccountState.SignedOut }
        } else {
            val attempt = buildAttempt(owner, validatedHomeserver(saved.session.homeserverUrl), saved)
            attempt.client.restoreSession(saved.session)
            finish(attempt)
        }
    }

    fun cancel() {
        val (oldJob, oldAttempt) = synchronized(lock) {
            generation++
            val job = operation
            operation = null
            val attempt = pending ?: connected
            attempt?.persistence?.deactivate()
            pending = null
            connected = null
            options = null
            mutableState.value = AccountState.SignedOut
            job to attempt
        }
        oldJob?.cancel()
        if (oldAttempt != null) {
            scope.launch(start = CoroutineStart.UNDISPATCHED) {
                withContext(NonCancellable + Dispatchers.IO) {
                    oldJob?.join()
                    dispose(oldAttempt)
                }
            }
        }
    }

    private fun runOperation(restoring: Boolean = false, block: suspend (Long) -> Unit) {
        synchronized(lock) {
            if (operation?.isActive == true || connected != null) return
            val owner = generation
            val serial = ++operationSerial
            mutableState.value = AccountState.Connecting(restoring, options)
            operation = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                try {
                    block(owner)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    val failed = synchronized(lock) {
                        if (owner != generation) null else {
                            val saved = error is SavedSessionUnavailable || restoring
                            operation = null
                            mutableState.value = AccountState.Failed(
                                if (saved) "Couldn’t restore your session. Try again."
                                else if (options == null) "Couldn’t connect to this server. Try again or choose another server."
                                else "Couldn’t sign in. Check your details and try again.",
                                saved, options,
                            )
                            pending.also { pending = null; it?.persistence?.deactivate() }
                        }
                    }
                    if (failed != null) withContext(NonCancellable) { dispose(failed) }
                } finally {
                    synchronized(lock) { if (owner == generation && serial == operationSerial) operation = null }
                }
            }.also { it.start() }
        }
    }

    private suspend fun freshAttempt(owner: Long, homeserver: String): Attempt {
        synchronized(lock) { pending?.let { checkOwner(owner); return it } }
        val saved = try { store.load() } catch (_: Exception) { throw SavedSessionUnavailable() }
        if (saved != null) throw SavedSessionUnavailable()
        return buildAttempt(owner, homeserver, null)
    }

    private suspend fun buildAttempt(owner: Long, homeserver: String, saved: StoredSession?): Attempt {
        val storeId = saved?.storeId ?: UUID.randomUUID().toString()
        val storeKey = saved?.storeKey ?: Base64.encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) }, Base64.NO_WRAP)
        val persistence = Persistence(owner, storeId, storeKey, saved)
        var client: Client? = null
        try {
            client = clientFactory(homeserver, storeId, storeKey, saved != null, persistence)
            val attempt = Attempt(owner, storeId, client, persistence, fresh = saved == null)
            synchronized(lock) { checkOwner(owner); pending = attempt }
            return attempt
        } catch (error: Exception) {
            synchronized(lock) { persistence.deactivate() }
            client?.close()
            cleanFreshStore(storeId, fresh = saved == null)
            throw error
        }
    }

    private fun finish(attempt: Attempt) {
        checkOwner(attempt.owner)
        val session = attempt.client.session()
        synchronized(lock) {
            checkOwner(attempt.owner)
            if (attempt.fresh) attempt.persistence.persist(session)
            pending = null
            connected = attempt
            operation = null
            mutableState.value = AccountState.Connected(attempt.client, session.userId, attempt.persistence.warning)
        }
    }

    private suspend fun dispose(attempt: Attempt) {
        synchronized(lock) {
            if (attempt.disposed) return
            attempt.disposed = true
            attempt.persistence.deactivate()
        }
        try { attempt.oauth?.let { attempt.client.abortOauthAuth(it) } } catch (_: Exception) { }
        attempt.oauth?.close()
        attempt.sso?.close()
        attempt.client.close()
        cleanFreshStore(attempt.storeId, attempt.fresh)
    }

    private fun cleanFreshStore(storeId: String, fresh: Boolean) {
        if (!fresh) return
        val referenced = try { store.load()?.storeId } catch (_: Exception) { return }
        if (referenced != storeId) File(rootDirectory, storeId).deleteRecursively()
    }

    private fun checkOwner(owner: Long) {
        scope.coroutineContext.ensureActive()
        synchronized(lock) { if (owner != generation) throw CancellationException() }
    }

    private inner class Attempt(val owner: Long, val storeId: String, val client: Client, val persistence: Persistence, val fresh: Boolean) {
        var oauth: OAuthAuthorizationData? = null
        var sso: SsoHandler? = null
        var nonce: String? = null
        var disposed = false
    }

    private class SavedSessionUnavailable : Exception()

    private inner class Persistence(
        private val owner: Long,
        private val storeId: String,
        private val storeKey: String,
        initial: StoredSession?,
    ) : ClientSessionDelegate {
        private var active = true
        private var cached = initial?.session?.copy()
        private var saved = initial != null
        var warning: String? = null
            private set

        override fun retrieveSessionFromKeychain(userId: String): Session = synchronized(lock) {
            if (!active || owner != generation || cached?.userId != userId) {
                throw ClientException.Generic("Stored session is unavailable.", null)
            }
            cached!!.copy()
        }

        override fun saveSessionInKeychain(session: Session) {
            synchronized(lock) {
                if (!active || owner != generation) return
                cached = session.copy()
                if (!saved) return
                try {
                    persist(session)
                    warning = null
                } catch (_: Exception) {
                    warning = "Couldn’t save your session. Keep Slatrix open."
                }
                val current = mutableState.value
                if (current is AccountState.Connected) mutableState.value = current.copy(warning = warning)
            }
        }

        fun deactivate() { active = false }

        fun persist(session: Session) {
            if (!saved && store.load() != null) throw SavedSessionUnavailable()
            store.save(StoredSession(session.copy(), storeId, storeKey))
            cached = session.copy()
            saved = true
        }
    }

    private fun callbackRoute(): String {
        val uri = URI(oauthConfiguration.redirectUri)
        require(uri.scheme != null && uri.rawQuery == null && uri.rawFragment == null && uri.rawUserInfo == null)
        return uri.toString()
    }

    private fun validCallbackRoute(url: String): Boolean {
        val expected = URI(callbackRoute())
        val actual = URI(url)
        return actual.scheme == expected.scheme && actual.rawAuthority == expected.rawAuthority &&
            actual.rawPath == expected.rawPath && actual.rawFragment == null
    }

    private fun validatedHomeserver(input: String): String {
        val trimmed = input.trim()
        val value = if (trimmed.contains("://")) trimmed else "https://$trimmed"
        val uri = URI(value)
        require(uri.scheme == "https" && !uri.host.isNullOrEmpty() && uri.rawUserInfo == null &&
            uri.rawQuery == null && uri.rawFragment == null)
        return value.trimEnd('/')
    }
}
