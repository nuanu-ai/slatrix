package ai.nuanu.slatrix

import android.Manifest
import android.app.Application
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.WorkManager
import ai.nuanu.slatrix.push.NotificationTarget
import ai.nuanu.slatrix.push.PushMessagingService
import ai.nuanu.slatrix.push.PushNotifications
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import org.matrix.rustcomponents.sdk.*
import org.robolectric.Shadows.shadowOf
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

    @Test fun onlyANotificationThisAppDeliveredCanOpenItsRoom() {
        val application = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val manager = application.getSystemService(NotificationManager::class.java)
        PushNotifications(application).show("@alex:example.org", "!team:example.org", "\$delivered", NotificationStatus.EventNotFound)
        val delivered = shadowOf(manager.activeNotifications.single().notification.contentIntent).savedIntent
        val forged = Intent(delivered).putExtra(PushNotifications.EVENT_ID, "\$never-delivered")

        for ((intent, expected) in listOf(forged to null, delivered to NotificationTarget("@alex:example.org", "!team:example.org"))) {
            ActivityScenario.launch<MainActivity>(intent).use { scenario ->
                scenario.onActivity { activity ->
                    assertEquals(expected, ViewModelProvider(activity)[AccountViewModel::class.java].notificationTarget.value)
                }
            }
        }
    }

    // capability: thread.from-notification
    @Test fun aThreadRepliesNotificationTargetsItsThread() {
        val application = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val manager = application.getSystemService(NotificationManager::class.java)
        val reply = NotificationStatus.Event(NotificationItem(
            event = NotificationEvent.Timeline(object : TimelineEvent(NoHandle) {
                override fun content(): TimelineEventContent = TimelineEventContent.MessageLike(
                    MessageLikeEventContent.RoomMessage(MessageType.Text(TextMessageContent("Agreed", null)), null))
                override fun senderId(): String = "@sam:example.org"
            }),
            rawEvent = "{}", senderInfo = NotificationSenderInfo("Sam", null, false),
            roomInfo = NotificationRoomInfo("Team", null, null, null, null, 2u, 0u, emptyList(), true, false, false, false),
            isNoisy = true, hasMention = false, threadId = "\$root", actions = null,
        ))
        PushNotifications(application).show("@alex:example.org", "!team:example.org", "\$reply", reply)
        val tap = shadowOf(manager.activeNotifications.single().notification.contentIntent).savedIntent

        ActivityScenario.launch<MainActivity>(tap).use { scenario ->
            scenario.onActivity { activity ->
                assertEquals(NotificationTarget("@alex:example.org", "!team:example.org", threadRoot = "\$root"),
                    ViewModelProvider(activity)[AccountViewModel::class.java].notificationTarget.value)
            }
        }
    }

    @Test fun firebaseDeliveryReachesThePrivateApplicationService() {
        val application = ApplicationProvider.getApplicationContext<Application>()
        val intent = Intent("com.google.firebase.MESSAGING_EVENT").setPackage(application.packageName)
        val service = application.packageManager.resolveService(intent, PackageManager.GET_META_DATA)!!.serviceInfo

        assertEquals("ai.nuanu.slatrix.push.PushMessagingService", service.name)
        assertFalse(service.exported)
    }
}
