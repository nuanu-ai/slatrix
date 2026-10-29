package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.RecoveryState
import org.matrix.rustcomponents.sdk.RecoveryStateListener
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.VerificationState
import org.matrix.rustcomponents.sdk.VerificationStateListener

enum class IdentityStatus { Unknown, Unverified, Verified }
enum class IdentityPhase {
    Preparing, ChooseMethod, Incoming, Requesting, WaitingForDevice, Exchanging,
    Comparing, AwaitingConfirmation, Recovering, Cancelling, Failed,
}
data class VerificationEmoji(val symbol: String, val name: String)
data class IdentityState(
    val status: IdentityStatus = IdentityStatus.Unknown,
    val phase: IdentityPhase = IdentityPhase.Preparing,
    val emojis: List<VerificationEmoji> = emptyList(),
    val decimals: List<Int> = emptyList(),
    val error: String? = null,
    val hasOtherDevice: Boolean? = null,
    val recoveryAvailable: Boolean? = null,
    val requestDeviceName: String? = null,
) {
    val verified: Boolean get() = status == IdentityStatus.Verified
}

class IdentityVerification(scope: CoroutineScope, private val client: Client) : AutoCloseable {
    private val serviceScope = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    private val encryption = client.encryption()
    private val mutableState = MutableStateFlow(IdentityState())
    val state = mutableState.asStateFlow()
    private var closed = false
    private var verificationHandle: TaskHandle? = null
    private var recoveryHandle: TaskHandle? = null

    init {
        serviceScope.launch {
            try {
                verificationHandle = encryption.verificationStateListener(object : VerificationStateListener {
                    override fun onUpdate(status: VerificationState) {
                        serviceScope.launch { if (!closed) updateStatus(status) }
                    }
                })
                recoveryHandle = encryption.recoveryStateListener(object : RecoveryStateListener {
                    override fun onUpdate(status: RecoveryState) {
                        serviceScope.launch { if (!closed) updateRecovery(status) }
                    }
                })
                encryption.waitForE2eeInitializationTasks()
                updateStatus(encryption.verificationState())
                updateRecovery(encryption.recoveryState())
                val hasOtherDevice = encryption.hasDevicesToVerifyAgainst()
                mutableState.update { it.copy(phase = IdentityPhase.ChooseMethod, hasOtherDevice = hasOtherDevice) }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                mutableState.update { it.copy(phase = IdentityPhase.Failed, error = "Couldn’t check this device. Try again.") }
            }
        }
    }

    override fun close() {
        closed = true
        verificationHandle?.cancel()
        recoveryHandle?.cancel()
        serviceScope.cancel()
    }

    private fun updateStatus(status: VerificationState) {
        mutableState.update {
            it.copy(status = when (status) {
                VerificationState.UNKNOWN -> IdentityStatus.Unknown
                VerificationState.UNVERIFIED -> IdentityStatus.Unverified
                VerificationState.VERIFIED -> IdentityStatus.Verified
            })
        }
    }

    private fun updateRecovery(status: RecoveryState) {
        mutableState.update {
            it.copy(recoveryAvailable = when (status) {
                RecoveryState.UNKNOWN -> null
                RecoveryState.DISABLED -> false
                RecoveryState.ENABLED, RecoveryState.INCOMPLETE -> true
            })
        }
    }
}
