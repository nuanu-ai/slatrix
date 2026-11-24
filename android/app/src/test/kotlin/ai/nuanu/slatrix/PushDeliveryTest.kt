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
import ai.nuanu.slatrix.push.PushRegistrationWorker
import ai.nuanu.slatrix.core.ConnectionState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
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
    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test fun reconnectingChecksPushRegistrationAgainWithoutRestartingTheApp() = runTest {
        val application = ApplicationProvider.getApplicationContext<Application>()
        val workManager = try {
            WorkManager.getInstance(application)
        } catch (_: IllegalStateException) {
            WorkManager.initialize(application, Configuration.Builder().build())
            WorkManager.getInstance(application)
        }
        val connection = MutableStateFlow(ConnectionState.Connected)
        val following = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            PushRegistrationWorker.followConnection(application, connection)
        }
        try {
            val first = workManager.getWorkInfosForUniqueWork("push-registration").get().map { it.id }.toSet()
            assertTrue(first.isNotEmpty())
            connection.value = ConnectionState.Reconnecting
            connection.value = ConnectionState.Connected
            val recovered = workManager.getWorkInfosForUniqueWork("push-registration").get()
            assertTrue("Recovery must schedule a fresh registration, even when an earlier attempt finished or failed",
                recovered.any { it.id !in first })
        } finally {
            following.cancel()
        }
    }

    // capability: notifications.alert
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

    // capability: notifications.open
    @Test fun onlyANotificationThisAppDeliveredCanOpenItsRoom() {
        val application = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val manager = application.getSystemService(NotificationManager::class.java)
        PushNotifications(application).show("@alex:example.org", "!team:example.org", "\$delivered", NotificationStatus.EventNotFound)
        val delivered = shadowOf(manager.activeNotifications.single().notification.contentIntent).savedIntent
        val forged = Intent(delivered).putExtra(PushNotifications.EVENT_ID, "\$never-delivered")

        for ((intent, expected) in listOf(forged to null, delivered to NotificationTarget("@alex:example.org", "!team:example.org", "\$delivered"))) {
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
                assertEquals(NotificationTarget("@alex:example.org", "!team:example.org", "\$reply", threadRoot = "\$root"),
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

    // capability: notifications.alert
    @Test fun aBadgeClearPushClearsMessageNotificationsWithoutCancellingReminders() {
        val application = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val manager = application.getSystemService(NotificationManager::class.java)
        manager.cancelAll()
        val notifications = PushNotifications(application)
        notifications.show("@alex:example.org", "!team:example.org", "\$msg", NotificationStatus.EventNotFound)
        notifications.remind("@alex:example.org", "!team:example.org", "\$later", "Team", "Reminder: Ship it")
        assertEquals(2, manager.activeNotifications.size)

        val service = Robolectric.buildService(PushMessagingService::class.java).create()
        service.get().onMessageReceived(RemoteMessage.Builder("fictional-sender")
            .setData(mapOf("unread" to "0"))
            .build())
        service.destroy()

        assertEquals(1, manager.activeNotifications.size)
        assertEquals("reminders", manager.activeNotifications.single().notification.channelId)
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    @Test fun activeOpenRoomTracksThreadsOpenedWithoutAnOpenChannel() = runTest {
        val roomA = ai.nuanu.slatrix.core.RoomSummary("!a:example.org", "A", false, "", ai.nuanu.slatrix.core.UnreadBadge.None, "A", 0)
        val roomB = ai.nuanu.slatrix.core.RoomSummary("!b:example.org", "B", false, "", ai.nuanu.slatrix.core.UnreadBadge.None, "B", 1)
        val client = object : Client(NoHandle) {
            override fun getRoom(roomId: String): Room = object : Room(NoHandle) {
                override fun id(): String = roomId
                override fun ownUserId(): String = "@me:example.org"
                override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline =
                    object : Timeline(NoHandle) {
                        override suspend fun addListener(listener: TimelineListener): TaskHandle =
                            object : TaskHandle(NoHandle) { override fun cancel() = Unit }
                    }
                override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? = null
            }
        }
        val workspace = ai.nuanu.slatrix.core.MatrixWorkspace(backgroundScope, client)
        val threads = ai.nuanu.slatrix.core.MatrixWorkspace(backgroundScope, client)
        val seen = mutableListOf<String?>()
        val job = backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            activeOpenRoom(MutableStateFlow(workspace), MutableStateFlow(threads)).collect { seen += it }
        }
        try {
            assertEquals(null, seen.last())
            threads.open(roomB, threadRoot = "\$root")
            assertEquals("!b:example.org", seen.last())
            threads.back()
            assertEquals(null, seen.last())
            workspace.open(roomA)
            assertEquals("!a:example.org", seen.last())
            threads.open(roomB, threadRoot = "\$root")
            assertEquals("!b:example.org", seen.last())
        } finally {
            job.cancel()
            threads.close()
            workspace.close()
        }
    }

    // capability: thread.from-notification
    @Test fun tappingAReminderForAThreadReplyResolvesItsThreadBeforeJumping() = runTest {
        val roomSummary = ai.nuanu.slatrix.core.RoomSummary("!team:example.org", "Team", false, "",
            ai.nuanu.slatrix.core.UnreadBadge.None, "T", 0)
        val client = object : Client(NoHandle) {
            override fun getRoom(roomId: String): Room = object : Room(NoHandle) {
                override fun id(): String = roomId
                override fun ownUserId(): String = "@alex:example.org"
                override suspend fun timelineWithConfiguration(configuration: TimelineConfiguration): Timeline =
                    object : Timeline(NoHandle) {
                        override suspend fun addListener(listener: TimelineListener): TaskHandle =
                            object : TaskHandle(NoHandle) { override fun cancel() = Unit }
                    }
                override suspend fun loadComposerDraft(threadRoot: String?): ComposerDraft? = null
                override suspend fun loadOrFetchEvent(eventId: String): TimelineEvent = object : TimelineEvent(NoHandle) {
                    override fun threadRootEventId(): String? = if (eventId == "\$reply") "\$root" else null
                }
            }
        }
        val workspace = ai.nuanu.slatrix.core.MatrixWorkspace(backgroundScope, client)
        val threads = ai.nuanu.slatrix.core.MatrixWorkspace(backgroundScope, client)
        var cleared = false
        try {
            ai.nuanu.slatrix.ui.account.openNotification(
                NotificationTarget("@alex:example.org", "!team:example.org", "\$reply", threadRoot = null),
                roomSummary, workspace, threads,
            ) { cleared = true }
            assertTrue(cleared)
            assertEquals("\$root", workspace.selected.value?.at)
            assertEquals("\$root", threads.selected.value?.threadRoot)
            assertEquals("\$reply", threads.selected.value?.at)
        } finally {
            threads.close()
            workspace.close()
        }
    }
}
