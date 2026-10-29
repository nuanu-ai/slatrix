package ai.nuanu.slatrix.core

import android.app.Application
import ai.nuanu.slatrix.BuildConfig
import ai.nuanu.slatrix.push.PushRegistration
import ai.nuanu.slatrix.push.PushRegistrationWorker
import android.app.NotificationManager
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.OAuthConfiguration

class AccountRuntime private constructor(application: Application) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val callbackScheme = "com.github.nuanu-ai.slatrix" + if (application.packageName.endsWith(".dev")) ".dev" else ""
    val account = MatrixAccount(scope, SessionStore(application), File(application.noBackupFilesDir, "matrix"),
        OAuthConfiguration(clientName = "Slatrix", redirectUri = "$callbackScheme:/oauth/callback",
            clientUri = "https://github.com/nuanu-ai/slatrix", logoUri = null, tosUri = null, policyUri = null,
            staticRegistrations = emptyMap()),
        onSignOut = { client ->
            application.getSystemService(NotificationManager::class.java).cancelAll()
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

    init {
        scope.launch {
            var client: Client? = null
            var registered = false
            combine(account.state, foreground, ::Pair).collect { (state, visible) ->
                val next = (state as? AccountState.Connected)?.client
                if (next !== client) {
                    mutableIdentity.value?.close()
                    mutableRooms.value?.close()
                    mutableActivity.value?.close()
                    mutableIdentity.value = null
                    mutableRooms.value = null
                    client = next
                    registered = false
                    // One sync service per client: a second would run a second encryption sync.
                    mutableRooms.value = next?.let { MatrixRooms(scope, it, foreground) }
                    mutableIdentity.value = next?.let { IdentityVerification(scope, it) }
                    mutableActivity.value = next?.let { client ->
                        MatrixActivity((state as AccountState.Connected).userId, scope, { roomId, eventId -> messageText(client, roomId, eventId) }).also {
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
                if (next != null && visible && !registered) {
                    registered = true
                    if (BuildConfig.PUSH_GATEWAY.isNotEmpty()) PushRegistrationWorker.enqueue(application)
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
