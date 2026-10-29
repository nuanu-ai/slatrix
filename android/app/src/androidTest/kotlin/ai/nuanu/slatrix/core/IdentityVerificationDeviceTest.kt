package ai.nuanu.slatrix.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.Encryption
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.RecoveryState
import org.matrix.rustcomponents.sdk.RecoveryStateListener
import org.matrix.rustcomponents.sdk.SessionVerificationController
import org.matrix.rustcomponents.sdk.SessionVerificationControllerDelegate
import org.matrix.rustcomponents.sdk.TaskHandle
import org.matrix.rustcomponents.sdk.VerificationState
import org.matrix.rustcomponents.sdk.VerificationStateListener

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
}

private class IdentityClient(private val identityEncryption: IdentityEncryption) : Client(NoHandle) {
    override fun encryption(): Encryption = identityEncryption
    override suspend fun getSessionVerificationController(): SessionVerificationController = IdentityController()
}

private class IdentityEncryption : Encryption(NoHandle) {
    override suspend fun waitForE2eeInitializationTasks() = Unit
    override fun verificationState(): VerificationState = VerificationState.UNKNOWN
    override fun verificationStateListener(listener: VerificationStateListener): TaskHandle = IdentityTask()
    override fun recoveryState(): RecoveryState = RecoveryState.ENABLED
    override fun recoveryStateListener(listener: RecoveryStateListener): TaskHandle = IdentityTask()
    override suspend fun hasDevicesToVerifyAgainst(): Boolean = true
}

private class IdentityController : SessionVerificationController(NoHandle) {
    override fun setDelegate(delegate: SessionVerificationControllerDelegate?) = Unit
}

private class IdentityTask : TaskHandle(NoHandle) {
    override fun cancel() = Unit
}
