package ai.nuanu.slatrix

import android.app.Application
import android.content.Intent
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.WorkManager
import ai.nuanu.slatrix.push.PushMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Robolectric
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class PushDeliveryTest {
    @Test fun firebaseEventDeliveryOutlivesTheMessagingServiceCallback() {
        val application = ApplicationProvider.getApplicationContext<Application>()
        val workManager = try {
            WorkManager.getInstance(application)
        } catch (_: IllegalStateException) {
            WorkManager.initialize(application, Configuration.Builder().build())
            WorkManager.getInstance(application)
        }
        val service = Robolectric.buildService(PushMessagingService::class.java).create()
        service.get().onMessageReceived(RemoteMessage.Builder("fictional-sender")
            .setData(mapOf("room_id" to "!team:example.org", "event_id" to "\$event"))
            .build())
        service.destroy()

        val durableDelivery = workManager.getWorkInfosByTag("ai.nuanu.slatrix.push.PushNotificationWorker").get()
        assertTrue("FCM delivery must remain scheduled after the service callback ends", durableDelivery.isNotEmpty())
    }

    @Test fun firebaseDeliveryReachesThePrivateApplicationService() {
        val application = ApplicationProvider.getApplicationContext<Application>()
        val intent = Intent("com.google.firebase.MESSAGING_EVENT").setPackage(application.packageName)
        val service = application.packageManager.resolveService(intent, PackageManager.GET_META_DATA)!!.serviceInfo

        assertEquals("ai.nuanu.slatrix.push.PushMessagingService", service.name)
        assertFalse(service.exported)
    }
}
