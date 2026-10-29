package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.MatrixAccount
import ai.nuanu.slatrix.core.AccountState
import ai.nuanu.slatrix.core.IdentityVerification
import ai.nuanu.slatrix.core.MatrixRooms
import ai.nuanu.slatrix.core.SessionStore
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import java.io.File
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.OAuthConfiguration

class AccountViewModel(application: Application) : AndroidViewModel(application) {
    private val callbackScheme = "com.github.nuanu-ai.slatrix" + if (application.packageName.endsWith(".dev")) ".dev" else ""
    val account = MatrixAccount(viewModelScope, SessionStore(application), File(application.noBackupFilesDir, "matrix"),
        OAuthConfiguration(clientName = "Slatrix", redirectUri = "$callbackScheme:/oauth/callback",
            clientUri = "https://github.com/nuanu-ai/slatrix", logoUri = null, tosUri = null, policyUri = null,
            staticRegistrations = emptyMap()))
    private val mutableIdentity = MutableStateFlow<IdentityVerification?>(null)
    val identity = mutableIdentity.asStateFlow()
    private val mutableRooms = MutableStateFlow<MatrixRooms?>(null)
    val rooms = mutableRooms.asStateFlow()

    init {
        viewModelScope.launch {
            var client: Client? = null
            try {
                account.state.collect { state ->
                    val next = (state as? AccountState.Connected)?.client
                    if (next !== client) {
                        mutableIdentity.value?.close()
                        mutableRooms.value?.close()
                        client = next
                        mutableRooms.value = next?.let { MatrixRooms(viewModelScope, it) }
                        mutableIdentity.value = next?.let { IdentityVerification(viewModelScope, it) }
                    }
                }
            } finally {
                withContext(NonCancellable) {
                    mutableIdentity.value?.close()
                    mutableRooms.value?.close()
                }
            }
        }
        account.restore()
    }
}
