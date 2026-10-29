package ai.nuanu.slatrix

import android.app.Application
import android.content.Intent
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class PushDeliveryTest {
    @Test fun firebaseDeliveryReachesThePrivateApplicationService() {
        val application = ApplicationProvider.getApplicationContext<Application>()
        val intent = Intent("com.google.firebase.MESSAGING_EVENT").setPackage(application.packageName)
        val services = application.packageManager.queryIntentServices(intent, PackageManager.GET_META_DATA)
        val service = services.single().serviceInfo

        assertEquals("ai.nuanu.slatrix.push.PushMessagingService", service.name)
        assertFalse(service.exported)
    }
}
