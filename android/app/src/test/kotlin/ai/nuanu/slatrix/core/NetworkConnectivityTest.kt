package ai.nuanu.slatrix.core

import android.app.Application
import android.net.ConnectivityManager
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetwork

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
@OptIn(ExperimentalCoroutinesApi::class)
class NetworkConnectivityTest {
    @Test fun networkChangesArriveAtOnceAndLosingAnOldNetworkDoesNotDisconnectTheNewOne() = runTest {
        val application = ApplicationProvider.getApplicationContext<Application>()
        val connectivity = shadowOf(application.getSystemService(ConnectivityManager::class.java))
        val available = MutableStateFlow<NetworkStatus?>(null)
        val job = backgroundScope.launch { networkAvailability(application).collect { available.value = it } }
        runCurrent()
        val callback = connectivity.networkCallbacks.single()
        try {
            val wifi = ShadowNetwork.newInstance(1)
            val mobile = ShadowNetwork.newInstance(2)
            callback.onAvailable(wifi)
            runCurrent()
            assertEquals(true, available.value?.available)
            callback.onAvailable(mobile)
            runCurrent()
            assertTrue("A new default route must interrupt the old socket", available.value?.routeChanged == true)
            callback.onLost(wifi)
            runCurrent()
            assertEquals(true, available.value?.available)
            callback.onLost(mobile)
            runCurrent()
            assertEquals(false, available.value?.available)
        } finally {
            job.cancelAndJoin()
        }
        assertFalse(callback in connectivity.networkCallbacks)
    }
}
