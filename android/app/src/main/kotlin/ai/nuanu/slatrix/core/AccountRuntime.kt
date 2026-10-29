package ai.nuanu.slatrix.core

import android.app.Application
import ai.nuanu.slatrix.BuildConfig
import ai.nuanu.slatrix.push.PushRegistrationWorker
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.OAuthConfiguration

class AccountRuntime private constructor(application: Application) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val callbackScheme = "com.github.nuanu-ai.slatrix" + if (application.packageName.endsWith(".dev")) ".dev" else ""
    val account = MatrixAccount(scope, SessionStore(application), File(application.noBackupFilesDir, "matrix"),
        OAuthConfiguration(clientName = "Slatrix", redirectUri = "$callbackScheme:/oauth/callback",
            clientUri = "https://github.com/nuanu-ai/slatrix", logoUri = null, tosUri = null, policyUri = null,
            staticRegistrations = emptyMap()))
    private val mutableIdentity = MutableStateFlow<IdentityVerification?>(null)
    val identity = mutableIdentity.asStateFlow()
    private val mutableRooms = MutableStateFlow<MatrixRooms?>(null)
    val rooms = mutableRooms.asStateFlow()

    init {
        scope.launch {
            var client: Client? = null
            account.state.collect { state ->
                val next = (state as? AccountState.Connected)?.client
                if (next !== client) {
                    mutableIdentity.value?.close()
                    mutableRooms.value?.close()
                    mutableIdentity.value = null
                    mutableRooms.value = null
                    client = next
                    mutableRooms.value = next?.let { MatrixRooms(scope, it) }
                    mutableIdentity.value = next?.let { IdentityVerification(scope, it) }
                    if (next != null && BuildConfig.PUSH_GATEWAY.isNotEmpty()) PushRegistrationWorker.enqueue(application)
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
