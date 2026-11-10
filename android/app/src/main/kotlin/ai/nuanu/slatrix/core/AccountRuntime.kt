package ai.nuanu.slatrix.core

import android.app.Application
import ai.nuanu.slatrix.BuildConfig
import ai.nuanu.slatrix.push.LaterReminders
import ai.nuanu.slatrix.push.PushRegistration
import ai.nuanu.slatrix.push.PushRegistrationWorker
import android.app.NotificationManager
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.OAuthConfiguration

/**
 * The main thread, for everything that calls the SDK. Never `Main.immediate`: the bindings wake an awaiting call from
 * inside the SDK call in progress, so it would run there and wait on that call's locks forever.
 */
val MatrixMain: CoroutineDispatcher = Dispatchers.Main

class AccountRuntime private constructor(application: Application) {
    private val scope = CoroutineScope(SupervisorJob() + MatrixMain)
    private val callbackScheme = "com.github.nuanu-ai.slatrix" + if (application.packageName.endsWith(".dev")) ".dev" else ""
    val account = MatrixAccount(scope, SessionStore(application), File(application.noBackupFilesDir, "matrix"),
        OAuthConfiguration(clientName = "Slatrix", redirectUri = "$callbackScheme:/oauth/callback",
            clientUri = "https://github.com/nuanu-ai/slatrix", logoUri = null, tosUri = null, policyUri = null,
            staticRegistrations = emptyMap()),
        File(application.cacheDir, "media"),
        onSignOut = { client ->
            application.getSystemService(NotificationManager::class.java).cancelAll()
            LaterReminders(application).sync(null, SavedList()) { "" to "" }
            PushRegistration(application).unregister(client, client.userId())
        })
    private val mutableIdentity = MutableStateFlow<IdentityVerification?>(null)
    val identity = mutableIdentity.asStateFlow()
    private val mutableRooms = MutableStateFlow<MatrixRooms?>(null)
    val rooms = mutableRooms.asStateFlow()
    private val mutableActivity = MutableStateFlow<MatrixActivity?>(null)
    val activity = mutableActivity.asStateFlow()

    // A push wakes the process without the UI; sync and push registration wait until the app is visible.
    private val foreground = ProcessLifecycleOwner.get().lifecycle.currentStateFlow
        .map { it.isAtLeast(Lifecycle.State.STARTED) }.stateIn(scope, SharingStarted.Eagerly, false)

    private val network = networkAvailability(application)

    init {
        scope.launch {
            var client: Client? = null
            var pushRegistration: Job? = null
            account.state.collect { state ->
                val next = (state as? AccountState.Connected)?.client
                if (next !== client) {
                    pushRegistration?.cancel()
                    pushRegistration = null
                    mutableIdentity.value?.close()
                    mutableRooms.value?.close()
                    mutableActivity.value?.close()
                    mutableIdentity.value = null
                    mutableRooms.value = null
                    client = next
                    // One sync service per client: a second would run a second encryption sync.
                    mutableRooms.value = next?.let {
                        MatrixRooms(scope, it, foreground, network).also { rooms ->
                            if (BuildConfig.PUSH_GATEWAY.isNotEmpty()) pushRegistration = scope.launch {
                                PushRegistrationWorker.followConnection(application, rooms.connection)
                            }
                        }
                    }
                    mutableIdentity.value = next?.let { IdentityVerification(scope, it) }
                    mutableActivity.value = next?.let { client ->
                        MatrixActivity((state as AccountState.Connected).userId, scope, { roomId, ids -> client.memberNames(roomId, ids) },
                            { roomId, eventId -> messageText(client, roomId, eventId) }).also {
                            scope.launch {
                                try {
                                    client.registerNotificationHandler(it.listener)
                                } catch (cancelled: CancellationException) {
                                    throw cancelled
                                } catch (_: Exception) {
                                    // Activity then lists only what pushes deliver.
                                }
                            }
                        }
                    }
                }
            }
        }
        account.restore()
    }

    companion object {
        @Volatile private var instance: AccountRuntime? = null

        fun get(application: Application): AccountRuntime = instance ?: synchronized(this) {
            instance ?: AccountRuntime(application).also { instance = it }
        }
    }
}
