package ai.nuanu.slatrix.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.ClientException
import org.matrix.rustcomponents.sdk.RecoveryState
import org.matrix.rustcomponents.sdk.RecoveryStateListener
import org.matrix.rustcomponents.sdk.SessionVerificationController
import org.matrix.rustcomponents.sdk.SessionVerificationControllerDelegate
import org.matrix.rustcomponents.sdk.SessionVerificationData
import org.matrix.rustcomponents.sdk.SessionVerificationRequestDetails
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
    val hasIdentity: Boolean? = null,
    val hasOtherDevice: Boolean? = null,
    val recoveryAvailable: Boolean? = null,
    val requestDeviceName: String? = null,
) {
    val verified: Boolean get() = status == IdentityStatus.Verified
    // An unknown status is still loading, unless checking failed and only a retry can settle it.
    val requiresVerification: Boolean get() = hasIdentity != false &&
        (status == IdentityStatus.Unverified || status == IdentityStatus.Unknown && phase == IdentityPhase.Failed)
}

class IdentityVerification(private val scope: CoroutineScope, private val client: Client) : AutoCloseable {
    private val serviceScope = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    private val encryption = client.encryption()
    private val mutableState = MutableStateFlow(IdentityState())
    val state = mutableState.asStateFlow()
    private var closed = false
    private val sdk = Mutex()
    private var flow = 0L
    private var flowScope = CoroutineScope(serviceScope.coroutineContext + SupervisorJob(serviceScope.coroutineContext[Job]))
    private var controller: SessionVerificationController? = null
    private var incoming: SessionVerificationRequestDetails? = null
    private var acceptedByUser = false
    private var confirmedByUser = false
    private var needsCancellation = false
    private var verificationHandle: TaskHandle? = null
    private var recoveryHandle: TaskHandle? = null

    init { prepare() }

    private fun prepare() {
        mutableState.update { it.copy(phase = IdentityPhase.Preparing, error = null) }
        serviceScope.launch {
            try {
                if (verificationHandle == null) verificationHandle = encryption.verificationStateListener(object : VerificationStateListener {
                    override fun onUpdate(status: VerificationState) {
                        serviceScope.launch { if (!closed) updateStatus(status) }
                    }
                })
                if (recoveryHandle == null) recoveryHandle = encryption.recoveryStateListener(object : RecoveryStateListener {
                    override fun onUpdate(status: RecoveryState) {
                        serviceScope.launch { if (!closed) updateRecovery(status) }
                    }
                })
                encryption.waitForE2eeInitializationTasks()
                updateStatus(encryption.verificationState())
                updateRecovery(encryption.recoveryState())
                val hasIdentity = encryption.userIdentity(client.userId(), true).use { it != null }
                coroutineContext.ensureActive()
                mutableState.update { it.copy(hasIdentity = hasIdentity) }
                val hasOtherDevice = if (hasIdentity) encryption.hasDevicesToVerifyAgainst() else false
                try {
                    if (hasIdentity) sdk.withLock { ensureController() }
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    // Recovery remains available when device verification is not ready yet.
                }
                coroutineContext.ensureActive()
                mutableState.update { it.copy(phase = IdentityPhase.ChooseMethod, hasOtherDevice = hasOtherDevice) }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                mutableState.update { it.copy(phase = IdentityPhase.Failed, error = "Couldn’t check this device. Try again.") }
            }
        }
    }

    fun recover(recoveryKey: String) {
        if (!canChoose()) return
        if (state.value.recoveryAvailable != true) {
            mutableState.update { it.copy(error = "Recovery isn’t available. Use another verified device.") }
            return
        }
        if (recoveryKey.isBlank()) {
            mutableState.update { it.copy(error = "Enter your recovery key to continue.") }
            return
        }
        beginFlow(IdentityPhase.Recovering)
        perform("Couldn’t use that recovery key. Check the key and your connection, then try again.") {
            encryption.recover(recoveryKey)
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            updateStatus(encryption.verificationState())
            updateRecovery(encryption.recoveryState())
            mutableState.update { it.copy(phase = IdentityPhase.ChooseMethod) }
        }
    }

    fun retry() {
        if (closed || state.value.phase !in listOf(IdentityPhase.Failed, IdentityPhase.ChooseMethod)) return
        if (needsCancellation) stopFlow() else prepare()
    }

    fun requestVerification() {
        if (!canChoose()) return
        if (state.value.hasOtherDevice != true) {
            mutableState.update { it.copy(error = "No verified device found. Use your recovery key.") }
            return
        }
        beginFlow(IdentityPhase.Requesting)
        acceptedByUser = true
        perform {
            ensureController().requestDeviceVerification()
            if (state.value.phase == IdentityPhase.Requesting) {
                mutableState.update { it.copy(phase = IdentityPhase.WaitingForDevice) }
            }
        }
    }

    fun acceptVerification() {
        val request = incoming ?: return
        if (closed || state.value.phase != IdentityPhase.Incoming) return
        acceptedByUser = true
        mutableState.update { it.copy(phase = IdentityPhase.Requesting, error = null) }
        perform {
            val controller = ensureController()
            controller.acknowledgeVerificationRequest(request.senderProfile.userId, request.flowId)
            controller.acceptVerificationRequest()
            if (state.value.phase == IdentityPhase.Requesting) {
                mutableState.update { it.copy(phase = IdentityPhase.Exchanging) }
                controller.startSasVerification()
            }
        }
    }

    fun confirmMatch() {
        if (closed || state.value.phase != IdentityPhase.Comparing || !acceptedByUser) return
        confirmedByUser = true
        mutableState.update { it.copy(phase = IdentityPhase.AwaitingConfirmation) }
        perform { ensureController().approveVerification() }
    }

    fun rejectMismatch() {
        if (closed || state.value.phase != IdentityPhase.Comparing) return
        mutableState.update { it.copy(phase = IdentityPhase.Cancelling) }
        perform {
            ensureController().declineVerification()
            stopFlow("The codes didn’t match. Try again.")
        }
    }

    fun cancel() {
        if (closed || state.value.phase == IdentityPhase.Cancelling) return
        stopFlow()
    }

    override fun close() {
        if (closed) return
        closed = true
        flow++
        val pending = flowScope.coroutineContext[Job]!!
        val activeController = controller.takeIf { acceptedByUser || incoming != null || needsCancellation }
        val request = incoming
        controller?.setDelegate(null)
        verificationHandle?.cancel()
        recoveryHandle?.cancel()
        serviceScope.cancel()
        if (activeController != null) {
            scope.launch(NonCancellable) {
                pending.join()
                sdk.withLock { try { cancelController(activeController, request) } catch (_: Exception) { } }
            }
        }
    }

    private fun canChoose(): Boolean = !closed && !needsCancellation && !state.value.verified &&
        state.value.phase in listOf(IdentityPhase.ChooseMethod, IdentityPhase.Failed)

    private fun beginFlow(phase: IdentityPhase) {
        flow++
        flowScope.cancel()
        flowScope = CoroutineScope(serviceScope.coroutineContext + SupervisorJob(serviceScope.coroutineContext[Job]))
        incoming = null
        acceptedByUser = false
        confirmedByUser = false
        controller?.setDelegate(observer(flow))
        mutableState.update { it.copy(phase = phase, error = null, emojis = emptyList(), decimals = emptyList(), requestDeviceName = null) }
    }

    private suspend fun ensureController(): SessionVerificationController {
        controller?.let { return it }
        val result = client.getSessionVerificationController()
        kotlinx.coroutines.currentCoroutineContext().ensureActive()
        controller = result
        result.setDelegate(observer(flow))
        return result
    }

    private fun perform(
        failureMessage: String = "Couldn’t verify this device. Check your connection and try again.",
        action: suspend () -> Unit,
    ) {
        val token = flow
        flowScope.launch {
            try {
                sdk.withLock {
                    if (!closed && flow == token) action()
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                if (!closed && flow == token) stopFlow(failureMessage)
            }
        }
    }

    private fun stopFlow(message: String? = null) {
        flow++
        val token = flow
        val pending = flowScope.coroutineContext[Job]!!
        pending.cancel()
        val oldController = controller
        val request = incoming
        oldController?.setDelegate(null)
        needsCancellation = acceptedByUser || incoming != null || needsCancellation
        acceptedByUser = false
        confirmedByUser = false
        incoming = null
        mutableState.update {
            it.copy(phase = IdentityPhase.Cancelling, emojis = emptyList(), decimals = emptyList(), requestDeviceName = null, error = message)
        }
        serviceScope.launch {
            pending.join()
            try {
                if (needsCancellation && oldController != null) sdk.withLock { cancelController(oldController, request) }
                if (closed || flow != token) return@launch
                needsCancellation = false
                flowScope = CoroutineScope(serviceScope.coroutineContext + SupervisorJob(serviceScope.coroutineContext[Job]))
                oldController?.setDelegate(observer(token))
                mutableState.update { it.copy(phase = if (message == null) IdentityPhase.ChooseMethod else IdentityPhase.Failed) }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                if (!closed && flow == token) {
                    mutableState.update { it.copy(phase = IdentityPhase.Failed, error = "Couldn’t stop verification. Try again.") }
                }
            }
        }
    }

    private suspend fun cancelController(controller: SessionVerificationController, request: SessionVerificationRequestDetails?) {
        if (request != null) {
            try {
                controller.acknowledgeVerificationRequest(request.senderProfile.userId, request.flowId)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                // The incoming request may have expired or already been acknowledged.
            }
        }
        try {
            controller.cancelVerification()
        } catch (error: ClientException.Generic) {
            if (!error.msg.contains("verification request missing", ignoreCase = true)) throw error
        }
    }

    private fun observer(token: Long) = object : SessionVerificationControllerDelegate {
        private fun receive(action: () -> Unit) {
            serviceScope.launch { if (!closed && flow == token) action() }
        }
        override fun didReceiveVerificationRequest(details: SessionVerificationRequestDetails) = receive {
            if (!canChoose() || details.senderProfile.userId != client.userId()) return@receive
            incoming = details
            mutableState.update { it.copy(phase = IdentityPhase.Incoming, error = null, requestDeviceName = details.deviceDisplayName ?: details.deviceId) }
        }
        override fun didAcceptVerificationRequest() = receive {
            if (!acceptedByUser || state.value.phase !in listOf(IdentityPhase.Requesting, IdentityPhase.WaitingForDevice)) return@receive
            mutableState.update { it.copy(phase = IdentityPhase.Exchanging) }
            perform { ensureController().startSasVerification() }
        }
        override fun didStartSasVerification() = receive {
            if (acceptedByUser && state.value.phase in listOf(IdentityPhase.Requesting, IdentityPhase.WaitingForDevice)) {
                mutableState.update { it.copy(phase = IdentityPhase.Exchanging) }
            }
        }
        override fun didReceiveVerificationData(data: SessionVerificationData) = receive {
            if (!acceptedByUser || state.value.phase != IdentityPhase.Exchanging) return@receive
            val emojis = (data as? SessionVerificationData.Emojis)?.emojis?.map {
                VerificationEmoji(it.symbol(), it.description())
            }.orEmpty()
            val decimals = (data as? SessionVerificationData.Decimals)?.values?.map { it.toInt() }.orEmpty()
            val valid = emojis.size == 7 && emojis.all { it.symbol.isNotBlank() && it.name.isNotBlank() } ||
                decimals.size == 3 && decimals.all { it in 1000..9191 }
            if (!valid) {
                stopFlow("Couldn’t compare these codes. Try again.")
            } else {
                mutableState.update { it.copy(phase = IdentityPhase.Comparing, emojis = emojis, decimals = decimals) }
            }
        }
        override fun didFail() = receive {
            if (state.value.phase != IdentityPhase.Cancelling && (acceptedByUser || incoming != null)) stopFlow("Verification failed. Try again from the other device.")
        }
        override fun didCancel() = receive {
            if (state.value.phase != IdentityPhase.Cancelling && (acceptedByUser || incoming != null)) stopFlow("Verification was cancelled or timed out. Try again.")
        }
        override fun didFinish() = receive {
            if (confirmedByUser && state.value.phase == IdentityPhase.AwaitingConfirmation) {
                mutableState.update { it.copy(emojis = emptyList(), decimals = emptyList()) }
            }
        }
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
