package ai.nuanu.slatrix.core

import android.app.Application
import android.os.Looper
import kotlin.coroutines.resume
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.coroutines.Continuation

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class MatrixMainTest {
    /**
     * The SDK's bindings resume an awaiting call from inside whatever SDK call the main thread is in, as the ANR on
     * opening a channel from a notification showed: a page of history waited there on the lock its timeline held.
     */
    @Test fun aCallTheSdkWakesFromInsideAnotherCallResumesAfterThatCallReturns() {
        var waiting: Continuation<Unit>? = null
        var insideSdkCall = false
        var resumedInside: Boolean? = null
        CoroutineScope(MatrixMain).launch {
            suspendCancellableCoroutine { waiting = it }
            resumedInside = insideSdkCall
        }
        shadowOf(Looper.getMainLooper()).idle()

        insideSdkCall = true
        checkNotNull(waiting).resume(Unit)
        insideSdkCall = false
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals(false, resumedInside)
    }
}
