package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.AccountRuntime
import ai.nuanu.slatrix.core.AccountState
import ai.nuanu.slatrix.core.MatrixWorkspace
import ai.nuanu.slatrix.push.NotificationTarget
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client

class AccountViewModel(application: Application) : AndroidViewModel(application) {
    private val runtime = AccountRuntime.get(application)
    val account = runtime.account
    val identity = runtime.identity
    val rooms = runtime.rooms
    private val mutableWorkspace = MutableStateFlow<MatrixWorkspace?>(null)
    val workspace = mutableWorkspace.asStateFlow()
    private val mutableNotificationTarget = MutableStateFlow<NotificationTarget?>(null)
    val notificationTarget = mutableNotificationTarget.asStateFlow()

    fun openNotification(target: NotificationTarget) { mutableNotificationTarget.value = target }

    fun notificationHandled(target: NotificationTarget) {
        if (mutableNotificationTarget.value == target) mutableNotificationTarget.value = null
    }

    init {
        viewModelScope.launch {
            var client: Client? = null
            try {
                account.state.collect { state ->
                    val next = (state as? AccountState.Connected)?.client
                    if (next !== client) {
                        mutableWorkspace.value?.close()
                        client = next
                        mutableWorkspace.value = next?.let { MatrixWorkspace(viewModelScope, it) }
                    }
                }
            } finally {
                withContext(NonCancellable) {
                    mutableWorkspace.value?.close()
                }
            }
        }
    }
}
