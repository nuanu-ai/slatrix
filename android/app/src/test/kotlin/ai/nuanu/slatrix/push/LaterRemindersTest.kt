package ai.nuanu.slatrix.push

import ai.nuanu.slatrix.AccountViewModel
import ai.nuanu.slatrix.MainActivity
import ai.nuanu.slatrix.core.LaterState
import ai.nuanu.slatrix.core.SavedList
import android.Manifest
import android.app.Application
import android.app.NotificationManager
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.WorkInfo
import androidx.work.WorkManager
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** Later's reminders through the real WorkManager queue and Android's notification manager. */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class LaterRemindersTest {
    private val application = ApplicationProvider.getApplicationContext<Application>()
    private val work = try {
        WorkManager.getInstance(application)
    } catch (_: IllegalStateException) {
        WorkManager.initialize(application, Configuration.Builder().build())
        WorkManager.getInstance(application)
    }
    private val user = "@alex:example.org"
    private val room = "!design:example.org"
    private val now = 1_761_955_200_000L

    private fun queued() = work.getWorkInfosByTag(LaterReminders.TAG).get().filter { it.state == WorkInfo.State.ENQUEUED }

    private fun sync(userId: String?, list: SavedList) = runBlocking {
        LaterReminders(application).sync(userId, list, now) { "#design" to "Reminder: Julia: launch notes" }
    }

    // capability: later.remind
    @Test fun aReminderToComeWaitsForItsTimeAndCompletingItWithdrawsIt() {
        var list = SavedList().reminding(room, "\$one", now + 3_600_000, now).reminding(room, "\$past", now - 60_000, now)
        sync(user, list)
        assertEquals(listOf("\$one"), queued().map { it.tags.single { tag -> tag.startsWith("later:") }.substringAfter(room).substringBefore('@') })
        assertEquals(listOf(now + 3_600_000), queued().map { it.initialDelayMillis + now })

        list = list.changing(room, "\$one", LaterState.COMPLETED, now)
        sync(user, list)
        assertEquals(emptyList<WorkInfo>(), queued())
    }

    @Test fun signingOutWithdrawsEveryReminder() {
        sync(user, SavedList().reminding(room, "\$one", now + 600_000, now))
        assertEquals(1, queued().size)
        sync(null, SavedList().reminding(room, "\$one", now + 600_000, now))
        assertEquals(emptyList<WorkInfo>(), queued())
    }

    // capability: later.remind
    @Test fun aDueReminderNotifiesAndOpensItsMessage() {
        shadowOf(application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        PushNotifications(application).remind(user, room, "\$one", "#design", "Reminder: Julia: launch notes")
        val notification = application.getSystemService(NotificationManager::class.java).activeNotifications.single().notification
        assertEquals("Reminder: Julia: launch notes", notification.extras.getString("android.text"))
        ActivityScenario.launch<MainActivity>(shadowOf(notification.contentIntent).savedIntent).use { scenario ->
            scenario.onActivity { activity ->
                assertEquals(NotificationTarget(user, room, "\$one"),
                    ViewModelProvider(activity)[AccountViewModel::class.java].notificationTarget.value)
            }
        }
    }
}
