package ai.nuanu.slatrix.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.Encryption
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.RecoveryState
import org.matrix.rustcomponents.sdk.RecoveryStateListener
import org.matrix.rustcomponents.sdk.SessionVerificationController
import org.matrix.rustcomponents.sdk.SessionVerificationControllerDelegate
import org.matrix.rustcomponents.sdk.SessionVerificationData
import org.matrix.rustcomponents.sdk.SessionVerificationRequestDetails
import org.matrix.rustcomponents.sdk.UserProfile
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.VerificationState
import org.matrix.rustcomponents.sdk.VerificationStateListener
import org.matrix.rustcomponents.sdk.UserIdentity

@RunWith(AndroidJUnit4::class)
class IdentityVerificationDeviceTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    @After fun tearDown() { scope.cancel() }

    @Test fun unresolvedIdentityNeverUnlocksTheAccountAfterEncryptionInitialization() = runBlocking {
        val encryption = IdentityEncryption()
        val verification = IdentityVerification(scope, IdentityClient(encryption))
        try {
            val ready = withTimeout(5_000) {
                verification.state.first { it.phase == IdentityPhase.ChooseMethod }
            }
            assertEquals(IdentityStatus.Unknown, ready.status)
            assertFalse(ready.verified)
        } finally {
            verification.close()
        }
    }
    @Test fun sasRequiresAnOwnerMatchAndSdkTrustBeforeUnlockingTheAccount() = runBlocking {
        val encryption = IdentityEncryption(VerificationState.UNVERIFIED)
        val controller = IdentityController()
        val verification = IdentityVerification(scope, IdentityClient(encryption, controller))
        try {
            withTimeout(5_000) { verification.state.first { it.phase == IdentityPhase.ChooseMethod } }
            verification.confirmMatch()
            assertFalse(controller.approved.isCompleted)
            verification.requestVerification()
            withTimeout(5_000) { controller.requested.await() }
            controller.observer!!.didAcceptVerificationRequest()
            val comparison = withTimeout(5_000) {
                verification.state.first { it.phase == IdentityPhase.Comparing }
            }
            assertEquals(listOf(1234, 5678, 9012), comparison.decimals)
            assertFalse(controller.approved.isCompleted)
            controller.observer!!.didFinish()
            assertFalse(verification.state.value.verified)

            verification.confirmMatch()
            withTimeout(5_000) { controller.approved.await() }
            controller.observer!!.didFinish()
            assertFalse(verification.state.value.verified)
            encryption.observer!!.onUpdate(VerificationState.VERIFIED)
            val trusted = withTimeout(5_000) { verification.state.first { it.verified } }
            assertTrue(trusted.verified)
        } finally {
            verification.close()
        }
    }
    @Test fun recoveryFailureKeepsTheSessionLockedAndCanRetryWithAnOwnerKey() = runBlocking<Unit> {
        val encryption = IdentityEncryption(VerificationState.UNVERIFIED)
        val verification = IdentityVerification(scope, IdentityClient(encryption))
        try {
            withTimeout(5_000) { verification.state.first { it.phase == IdentityPhase.ChooseMethod } }
            val invalidKey = "fictional-invalid-owner-recovery-key"
            encryption.recoverAction = { throw IllegalArgumentException("Invalid key: $it") }
            verification.recover(invalidKey)
            val failure = withTimeout(5_000) { verification.state.first { it.phase == IdentityPhase.Failed } }
            assertEquals(IdentityStatus.Unverified, failure.status)
            assertNotNull(failure.error)
            assertFalse(failure.toString().contains(invalidKey))

            verification.retry()
            withTimeout(5_000) { verification.state.first { it.phase == IdentityPhase.ChooseMethod } }
            encryption.recoverAction = { key ->
                if (key == "fictional-valid-owner-recovery-key") encryption.sdkState = VerificationState.VERIFIED
            }
            verification.recover("fictional-valid-owner-recovery-key")
            withTimeout(5_000) { verification.state.first { it.verified } }
        } finally {
            verification.close()
        }
    }

    @Test fun absentCrossSigningIdentityDoesNotTrapANewAccountBehindVerification() = runBlocking {
        val encryption = IdentityEncryption(VerificationState.UNVERIFIED)
        encryption.identityAction = { null }
        val verification = IdentityVerification(scope, IdentityClient(encryption))
        try {
            val ready = withTimeout(5_000) {
                verification.state.first { it.phase == IdentityPhase.ChooseMethod }
            }
            assertEquals(false, ready.hasIdentity)
            assertFalse(ready.verified)
            assertFalse(ready.requiresVerification)
        } finally {
            verification.close()
        }
    }

    @Test fun cancellingAnIncomingRequestAllowsANewFlowAndIgnoresItsStaleDelegate() = runBlocking {
        val encryption = IdentityEncryption(VerificationState.UNVERIFIED)
        val controller = IdentityController(requireAcknowledgement = true)
        val verification = IdentityVerification(scope, IdentityClient(encryption, controller))
        try {
            withTimeout(5_000) { verification.state.first { it.phase == IdentityPhase.ChooseMethod } }
            val oldDelegate = controller.observer!!
            oldDelegate.didReceiveVerificationRequest(SessionVerificationRequestDetails(
                UserProfile("@alice:example.org", "Alice", null, null, null),
                "incoming-flow", "OTHER", "Alice’s laptop", 1uL,
            ))
            withTimeout(5_000) { verification.state.first { it.phase == IdentityPhase.Incoming } }
            verification.cancel()
            withTimeout(5_000) { controller.cancelled.await() }
            withTimeout(5_000) { verification.state.first { it.phase == IdentityPhase.ChooseMethod } }
            verification.requestVerification()
            withTimeout(5_000) { controller.requested.await() }
            controller.observer!!.didAcceptVerificationRequest()
            withTimeout(5_000) { verification.state.first { it.phase == IdentityPhase.Comparing } }
            oldDelegate.didCancel()
            assertEquals(IdentityPhase.Comparing, verification.state.value.phase)
            verification.rejectMismatch()
            withTimeout(5_000) { controller.declined.await() }
            withTimeout(5_000) { verification.state.first { it.phase == IdentityPhase.Failed } }
            assertFalse(controller.approved.isCompleted)
        } finally {
            verification.close()
        }
    }

}

private class IdentityClient(
    private val identityEncryption: IdentityEncryption,
    private val controller: IdentityController = IdentityController(),
) : Client(NoHandle) {
    override fun userId(): String = "@alice:example.org"
    override fun encryption(): Encryption = identityEncryption
    override suspend fun getSessionVerificationController(): SessionVerificationController = controller
}

private class IdentityEncryption(var sdkState: VerificationState = VerificationState.UNKNOWN) : Encryption(NoHandle) {
    var observer: VerificationStateListener? = null
    var recoverAction: suspend (String) -> Unit = {}
    var identityAction: suspend () -> UserIdentity? = { UserIdentity(NoHandle) }
    override suspend fun userIdentity(userId: String, fallbackToServer: Boolean): UserIdentity? = identityAction()
    override suspend fun waitForE2eeInitializationTasks() = Unit
    override fun verificationState(): VerificationState = sdkState
    override fun verificationStateListener(listener: VerificationStateListener): TaskHandle {
        observer = listener
        return IdentityTask()
    }
    override fun recoveryState(): RecoveryState = RecoveryState.ENABLED
    override fun recoveryStateListener(listener: RecoveryStateListener): TaskHandle = IdentityTask()
    override suspend fun hasDevicesToVerifyAgainst(): Boolean = true
    override suspend fun recover(recoveryKey: String) { recoverAction(recoveryKey) }
}

private class IdentityController(private val requireAcknowledgement: Boolean = false) : SessionVerificationController(NoHandle) {
    var observer: SessionVerificationControllerDelegate? = null
    val requested = CompletableDeferred<Unit>()
    val approved = CompletableDeferred<Unit>()
    val cancelled = CompletableDeferred<Unit>()
    val declined = CompletableDeferred<Unit>()
    private var acknowledged = false
    override suspend fun acknowledgeVerificationRequest(senderId: String, flowId: String) { acknowledged = true }
    override fun setDelegate(delegate: SessionVerificationControllerDelegate?) { observer = delegate }
    override suspend fun requestDeviceVerification() { acknowledged = true; requested.complete(Unit) }
    override suspend fun startSasVerification() {
        observer!!.didReceiveVerificationData(SessionVerificationData.Decimals(listOf(1234u, 5678u, 9012u).map { it.toUShort() }))
    }
    override suspend fun approveVerification() { approved.complete(Unit) }
    override suspend fun declineVerification() { declined.complete(Unit) }
    override suspend fun cancelVerification() {
        check(!requireAcknowledgement || acknowledged) { "verification request missing" }
        cancelled.complete(Unit)
    }
}

private class IdentityTask : TaskHandle(NoHandle) {
    override fun cancel() = Unit
}
