package ai.nuanu.slatrix.core

import android.util.Base64
import java.io.File
import java.net.URI
import java.security.SecureRandom
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.ClientBuilder
import org.matrix.rustcomponents.sdk.ClientException
import org.matrix.rustcomponents.sdk.ClientSessionDelegate
import org.matrix.rustcomponents.sdk.Session
import org.matrix.rustcomponents.sdk.SlidingSyncVersionBuilder
import org.matrix.rustcomponents.sdk.SqliteStoreBuilder

sealed interface AccountState {
    data object SignedOut : AccountState
    data object Connecting : AccountState
    data class Connected(val client: Client, val userId: String, val warning: String? = null) : AccountState
    data class Failed(val message: String, val canRetryRestore: Boolean) : AccountState
}

class MatrixAccount(
    private val scope: CoroutineScope,
    private val store: SessionStore,
    rootDirectory: File,
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
    private var persistence: Persistence? = null
    private var connectedClient: Client? = null

    init { scope.coroutineContext[Job]?.invokeOnCompletion { cancel() } }

    fun restore() = authenticate(restoring = true)

    fun signIn(homeserver: String, username: String, password: String) =
        authenticate(restoring = false, homeserver, username, password)

    fun cancel() {
        val oldClient = synchronized(lock) {
            generation++
            operation?.cancel()
            operation = null
            persistence = null
            mutableState.value = AccountState.SignedOut
            connectedClient.also { connectedClient = null }
        }
        oldClient?.close()
    }

    private fun authenticate(
        restoring: Boolean,
        homeserver: String = "",
        username: String = "",
        password: String = "",
    ) {
        synchronized(lock) {
            if (operation?.isActive == true || connectedClient != null) return
            val owner = ++generation
            mutableState.value = AccountState.Connecting
            operation = scope.launch(Dispatchers.IO, start = CoroutineStart.LAZY) {
                var client: Client? = null
                var adopted = false
                var retryRestore = true
                var delegate: Persistence? = null
                try {
                    val saved = store.load()
                    retryRestore = saved != null
                    checkOwner(owner)
                    if (restoring && saved == null) {
                        synchronized(lock) { checkOwner(owner); mutableState.value = AccountState.SignedOut }
                        return@launch
                    }
                    if (!restoring && saved != null) {
                        synchronized(lock) {
                            checkOwner(owner)
                            mutableState.value = AccountState.Failed("Restore your saved session to continue.", true)
                        }
                        return@launch
                    }
                    val server = validatedHomeserver(if (restoring) saved!!.session.homeserverUrl else homeserver)
                    require(restoring || (username.trim().isNotEmpty() && password.isNotEmpty()))
                    val storeId = saved?.storeId ?: UUID.randomUUID().toString()
                    val storeKey = saved?.storeKey ?: Base64.encodeToString(
                        ByteArray(32).also { SecureRandom().nextBytes(it) }, Base64.NO_WRAP,
                    )
                    val activeDelegate = Persistence(owner, storeId, storeKey, saved)
                    delegate = activeDelegate
                    val newClient = clientFactory(server, storeId, storeKey, restoring, activeDelegate)
                    client = newClient
                    checkOwner(owner)
                    if (restoring) {
                        newClient.restoreSession(saved!!.session)
                    } else {
                        newClient.login(username.trim(), password, "Slatrix · Android", null)
                    }
                    checkOwner(owner)
                    val session = newClient.session()
                    synchronized(lock) {
                        checkOwner(owner)
                        if (!restoring) activeDelegate.persist(session)
                        persistence = activeDelegate
                        connectedClient = newClient
                        mutableState.value = AccountState.Connected(newClient, session.userId, activeDelegate.warning)
                        adopted = true
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    synchronized(lock) {
                        if (owner == generation) {
                            mutableState.value = AccountState.Failed(
                                if (retryRestore) "Couldn’t restore your session. Try again."
                                else "Couldn’t sign in. Check your details and try again.",
                                retryRestore,
                            )
                        }
                    }
                } finally {
                    if (!adopted) {
                        synchronized(lock) { delegate?.deactivate() }
                        client?.close()
                    }
                    synchronized(lock) { if (owner == generation) operation = null }
                }
            }.also { it.start() }
        }
    }

    private fun checkOwner(owner: Long) {
        scope.coroutineContext.ensureActive()
        synchronized(lock) { if (owner != generation) throw CancellationException() }
    }

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
            store.save(StoredSession(session.copy(), storeId, storeKey))
            cached = session.copy()
            saved = true
        }
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
