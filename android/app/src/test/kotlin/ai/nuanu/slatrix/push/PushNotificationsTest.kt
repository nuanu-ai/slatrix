package ai.nuanu.slatrix.push

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import ai.nuanu.slatrix.core.IdentityState
import ai.nuanu.slatrix.core.IdentityStatus
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.*
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class PushNotificationsTest {
    @Test fun identityConfirmationKeepsResolvedMessageContentPrivateByDefault() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val manager = context.getSystemService(NotificationManager::class.java)

        for ((event, identity) in listOf(
            "\$default" to null,
            "\$unknown" to IdentityState(),
            "\$unverified" to IdentityState(status = IdentityStatus.Unverified),
        )) {
            manager.cancelAll()
            PushNotifications(context).show("@alex:example.org", "!team:example.org", event, notificationMessage(), identity)

            val notification = manager.activeNotifications.single().notification
            assertEquals("Slatrix", notification.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
            assertEquals("New message", notification.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        }

        manager.cancelAll()
        PushNotifications(context).show("@alex:example.org", "!team:example.org", "\$new-account", notificationMessage(),
            IdentityState(status = IdentityStatus.Unverified, hasIdentity = false))
        assertEquals("Sam: Review budget?", manager.activeNotifications.single().notification.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
    }

    @Test @Config(sdk = [25]) fun noisyEventsUseSystemSoundBeforeNotificationChannels() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val manager = context.getSystemService(NotificationManager::class.java)
        val notifications = PushNotifications(context)
        notifications.show("@alex:example.org", "!team:example.org", "\$noisy", notificationMessage())
        assertTrue(manager.activeNotifications.single().notification.defaults and Notification.DEFAULT_SOUND != 0)

        manager.cancelAll()
        notifications.show("@alex:example.org", "!team:example.org", "\$quiet", notificationMessage(noisy = false))
        assertEquals(0, manager.activeNotifications.single().notification.defaults and Notification.DEFAULT_SOUND)
    }

    @Test fun sdkPrivacyDecisionsAndDismissedDuplicatesSurviveNotificationDelivery() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val manager = context.getSystemService(NotificationManager::class.java)
        val notifications = PushNotifications(context)
        val user = "@alex:example.org"
        val room = "!team:example.org"

        notifications.show(user, room, "\$filtered", NotificationStatus.EventFilteredOut)
        notifications.show(user, room, "\$redacted", NotificationStatus.EventRedacted)
        assertTrue(manager.activeNotifications.isEmpty())

        notifications.show(user, room, "\$resolved", notificationMessage(), identity = IdentityState(status = IdentityStatus.Verified))
        val notification = manager.activeNotifications.single().notification
        assertEquals("Team", notification.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals("Sam: Review budget?", notification.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertEquals(Notification.VISIBILITY_PRIVATE, notification.visibility)
        assertEquals("New message", notification.publicVersion.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertTrue(notification.contentIntent.isImmutable)
        val target = shadowOf(notification.contentIntent).savedIntent
        assertEquals(user, target.getStringExtra(PushNotifications.USER_ID))
        assertEquals(room, target.getStringExtra(PushNotifications.ROOM_ID))

        manager.cancelAll()
        PushNotifications(context).show(user, room, "\$resolved", notificationMessage(), identity = IdentityState(status = IdentityStatus.Verified))
        assertTrue("A repeated gateway delivery must not resurrect a dismissed notification", manager.activeNotifications.isEmpty())

        notifications.show(user, room, "\$missing", NotificationStatus.EventNotFound)
        val fallback = manager.activeNotifications.single().notification
        assertEquals("Slatrix", fallback.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals("New message", fallback.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
    }

    // capability: notifications.alert
    @Test fun aPushForAnEventNobodyCanFindAlertsOnlyInAJoinedRoom() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val manager = context.getSystemService(NotificationManager::class.java)
        val notifications = PushNotifications(context)
        val client = object : Client(NoHandle) {
            override fun getRoom(roomId: String): Room? = if (roomId != "!team:example.org") null else object : Room(NoHandle) {
                override fun membership() = Membership.JOINED
            }
        }

        notifications.deliver(client, "@alex:example.org", "!forged:example.org", "\$missing", NotificationStatus.EventNotFound, null)
        notifications.deliver(client, "@alex:example.org", "!forged:example.org", "\$unresolved", null, null)
        assertTrue(manager.activeNotifications.isEmpty())

        notifications.deliver(client, "@alex:example.org", "!team:example.org", "\$missing", NotificationStatus.EventNotFound, null)
        assertEquals("New message", manager.activeNotifications.single().notification.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
    }

    @Test fun aColdStartWaitsBrieflyForTheIdentityBeforeChoosingWhatToShow() = runTest {
        val identity = MutableStateFlow(IdentityState())
        val known = async { PushNotifications.knownIdentity(identity) }
        runCurrent()
        identity.value = IdentityState(status = IdentityStatus.Verified)
        assertEquals(IdentityStatus.Verified, known.await()?.status)

        identity.value = IdentityState()
        assertEquals(IdentityStatus.Unknown, PushNotifications.knownIdentity(identity)?.status)
    }

    @Test fun theOpenConversationRaisesNoAlertAndClearingARoomRemovesOnlyItsAlerts() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(context).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val manager = context.getSystemService(NotificationManager::class.java)
        val notifications = PushNotifications(context)
        val verified = IdentityState(status = IdentityStatus.Verified)

        PushNotifications.openRoom = "!team:example.org"
        try {
            notifications.show("@alex:example.org", "!team:example.org", "\$while-open", notificationMessage(), verified)
            assertTrue(manager.activeNotifications.isEmpty())
        } finally {
            PushNotifications.openRoom = null
        }

        notifications.show("@alex:example.org", "!team:example.org", "\$first", notificationMessage(), verified)
        notifications.show("@alex:example.org", "!team:example.org", "\$second", notificationMessage(), verified)
        notifications.show("@alex:example.org", "!other:example.org", "\$elsewhere", notificationMessage(), verified)
        notifications.clear("!team:example.org")

        val remaining = manager.activeNotifications.single().notification
        assertEquals("!other:example.org", shadowOf(remaining.contentIntent).savedIntent.getStringExtra(PushNotifications.ROOM_ID))
    }
}

private fun notificationMessage(noisy: Boolean = true) = NotificationStatus.Event(NotificationItem(
    event = NotificationEvent.Timeline(object : TimelineEvent(NoHandle) {
        override fun content(): TimelineEventContent = TimelineEventContent.MessageLike(
            MessageLikeEventContent.RoomMessage(MessageType.Text(TextMessageContent("Review budget?", null)), null))
        override fun senderId(): String = "@sam:example.org"
    }),
    rawEvent = """{"type":"m.room.message","content":{"msgtype":"m.text","body":"Review budget?"}}""",
    senderInfo = NotificationSenderInfo("Sam", null, false),
    roomInfo = NotificationRoomInfo("Team", null, null, null, null, 2u, 0u, emptyList(), true, false, false, false),
    isNoisy = noisy, hasMention = false, threadId = null, actions = null,
))
