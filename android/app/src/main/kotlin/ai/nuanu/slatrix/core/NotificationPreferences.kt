package ai.nuanu.slatrix.core

import android.app.NotificationManager
import android.content.Context
import androidx.core.content.edit
import org.matrix.rustcomponents.sdk.NotificationSettings
import org.matrix.rustcomponents.sdk.RoomNotificationMode.ALL_MESSAGES
import org.matrix.rustcomponents.sdk.RoomNotificationMode.MENTIONS_AND_KEYWORDS_ONLY

enum class NotifyAbout(val label: String) {
    All("All new messages"),
    DirectAndMentions("Direct messages, mentions & keywords"),
    Nothing("Nothing"),
}

/**
 * What notifies on this phone. All and DirectAndMentions are the account's default push rules, shared with the Mac;
 * Nothing silences only this phone, since the SDK can't mute an account's defaults.
 */
class NotificationPreferences(private val context: Context) {
    private val values = context.getSharedPreferences("notifications", Context.MODE_PRIVATE)

    val paused: Boolean get() = values.getBoolean("paused", false)

    var previews: Boolean
        get() = values.getBoolean("previews", true)
        set(value) {
            values.edit(commit = true) { putBoolean("previews", value) }
            // Alerts already up still show the text.
            if (!value) context.getSystemService(NotificationManager::class.java).cancelAll()
        }

    /** Null when the account's rules, set elsewhere, match none of the choices. */
    suspend fun notifyAbout(settings: NotificationSettings): NotifyAbout? {
        if (paused) return NotifyAbout.Nothing
        val direct = listOf(true, false).map { settings.getDefaultRoomNotificationMode(it, true) }
        val groups = listOf(true, false).map { settings.getDefaultRoomNotificationMode(it, false) }
        return when {
            direct.any { it != ALL_MESSAGES } -> null
            groups.all { it == ALL_MESSAGES } -> NotifyAbout.All
            groups.all { it == MENTIONS_AND_KEYWORDS_ONLY } -> NotifyAbout.DirectAndMentions
            else -> null
        }
    }

    suspend fun setNotifyAbout(settings: NotificationSettings, choice: NotifyAbout) {
        if (choice != NotifyAbout.Nothing) {
            val groups = if (choice == NotifyAbout.All) ALL_MESSAGES else MENTIONS_AND_KEYWORDS_ONLY
            for (encrypted in listOf(true, false)) {
                settings.setDefaultRoomNotificationMode(encrypted, true, ALL_MESSAGES)
                settings.setDefaultRoomNotificationMode(encrypted, false, groups)
            }
        }
        values.edit(commit = true) { putBoolean("paused", choice == NotifyAbout.Nothing) }
    }
}
