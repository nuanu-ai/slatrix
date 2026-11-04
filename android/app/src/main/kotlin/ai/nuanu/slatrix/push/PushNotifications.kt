package ai.nuanu.slatrix.push

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import ai.nuanu.slatrix.MainActivity
import ai.nuanu.slatrix.R
import ai.nuanu.slatrix.core.IdentityState
import ai.nuanu.slatrix.core.IdentityStatus
import ai.nuanu.slatrix.core.NotificationPreferences
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import java.security.MessageDigest
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.Membership
import org.matrix.rustcomponents.sdk.MessageLikeEventContent
import org.matrix.rustcomponents.sdk.MessageType
import org.matrix.rustcomponents.sdk.NotificationEvent
import org.matrix.rustcomponents.sdk.NotificationStatus
import org.matrix.rustcomponents.sdk.TimelineEventContent

class PushNotifications(private val context: Context) {
    private val manager = context.getSystemService(NotificationManager::class.java)
    private val preferences = context.getSharedPreferences("push-delivery", Context.MODE_PRIVATE)
    val enabled: Boolean get() = manager.areNotificationsEnabled() &&
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun deliver(client: Client, userId: String, roomId: String, eventId: String, status: NotificationStatus?, identity: IdentityState?) {
        // Anyone holding the push token can name any event; only a joined room earns an alert we can't resolve.
        if (status !is NotificationStatus.Event &&
            runCatching { client.getRoom(roomId)?.membership() }.getOrNull() != Membership.JOINED) return
        show(userId, roomId, eventId, status, identity)
    }

    fun delivered(userId: String, roomId: String, eventId: String): Boolean = synchronized(deliveryLock) {
        pushKey(userId, roomId, eventId) in preferences.getString("delivered", "").orEmpty().split('\n')
    }

    fun clear(roomId: String) = manager.activeNotifications.filter { it.tag == roomId }.forEach { manager.cancel(it.tag, it.id) }

    @SuppressLint("UseKtx") // KTX edit discards the commit result.
    fun show(userId: String, roomId: String, eventId: String, status: NotificationStatus?, identity: IdentityState? = null) = synchronized(deliveryLock) {
        val settings = NotificationPreferences(context, userId)
        if (!enabled || settings.paused || status is NotificationStatus.EventFilteredOut || status is NotificationStatus.EventRedacted || roomId == openRoom) return@synchronized
        val key = pushKey(userId, roomId, eventId)
        val delivered = preferences.getString("delivered", "").orEmpty().split('\n').filter { it.isNotEmpty() }
        if (key in delivered) return@synchronized

        val resolved = (status as? NotificationStatus.Event)?.item
        val item = resolved?.takeIf { identity != null && identity.status != IdentityStatus.Unknown && !identity.requiresVerification }
        val event = (item?.event as? NotificationEvent.Timeline)?.event
        val content = (event?.content() as? TimelineEventContent.MessageLike)?.content
        if (content is MessageLikeEventContent.RoomRedaction) return@synchronized
        val body = when (val message = (content as? MessageLikeEventContent.RoomMessage)?.messageType) {
            is MessageType.Text -> message.content.body
            is MessageType.Notice -> message.content.body
            is MessageType.Emote -> message.content.body
            else -> null
        }?.takeIf { settings.previews && it.isNotBlank() }?.take(512)
        val room = item?.roomInfo?.displayName?.takeIf { it.isNotBlank() } ?: "Slatrix"
        val sender = item?.senderInfo?.displayName?.takeIf { it.isNotBlank() } ?: event?.senderId()
        val (title, text) = when {
            body == null -> "Slatrix" to "New message"
            sender == null -> room to NotificationText.plain(body)
            else -> NotificationText.message(room, sender, item?.roomInfo?.isDirect == true, body)
        }
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Messages", NotificationManager.IMPORTANCE_DEFAULT))
        val intent = Intent(context, MainActivity::class.java)
            .setAction("${context.packageName}.OPEN_NOTIFICATION")
            .setData("slatrix://notification/$key".toUri())
            .putExtra(USER_ID, userId).putExtra(ROOM_ID, roomId).putExtra(EVENT_ID, eventId).putExtra(THREAD_ID, resolved?.threadId)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val tap = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun builder() = NotificationCompat.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(tap).setAutoCancel(true)
        val publicNotification = builder().setContentTitle("Slatrix").setContentText("New message").build()
        val notification = builder().setContentTitle(title).setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(publicNotification)
            .setOnlyAlertOnce(true).setSilent(resolved?.isNoisy != true).build()
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return@synchronized
        manager.notify(roomId, key.hashCode(), notification)
        check(preferences.edit().putString("delivered", (delivered + key).takeLast(512).joinToString("\n")).commit())
    }

    companion object {
        const val USER_ID = "push_user_id"
        const val ROOM_ID = "push_room_id"
        const val EVENT_ID = "push_event_id"
        const val THREAD_ID = "push_thread_id"

        /** The conversation on screen while the app is resumed; it needs no alert. */
        @Volatile var openRoom: String? = null

        /** On a cold start the identity is still loading; waiting a moment lets a verified device show the message. */
        suspend fun knownIdentity(identity: StateFlow<IdentityState>?): IdentityState? = identity?.let {
            withTimeoutOrNull(5_000) { it.first { state -> state.status != IdentityStatus.Unknown } } ?: it.value
        }
        private const val CHANNEL = "messages"
        private val deliveryLock = Any()
    }
}

/** What a message notification says, as the cases in `spec/notification-text.json` say. */
internal object NotificationText {
    fun message(room: String, sender: String, direct: Boolean, body: String): Pair<String, String> =
        plain(body).let { if (direct) sender to it else room to "$sender: $it" }

    private val markers = listOf(
        "\\*\\*(.+?)\\*\\*", "__(.+?)__", "~~(.+?)~~", "`([^`]+)`",
        "(?<![\\w*])\\*(?!\\s)(.+?)(?<!\\s)\\*(?![\\w*])", "(?<![\\w_])_(?!\\s)(.+?)(?<!\\s)_(?![\\w_])",
    ).map(::Regex)

    fun plain(body: String): String {
        var lines = body.split("\n")
        // A reply's body opens with the quoted message, "> <@sender> …", and a blank line.
        val blank = lines.indexOfFirst { !it.startsWith(">") }
        if (lines.first().startsWith("> <") && blank >= 0 && lines[blank].isEmpty()) lines = lines.drop(blank + 1)
        val joined = lines.filterNot { it.trim().startsWith("```") }
            .joinToString(" ") { if (it.startsWith(">")) it.drop(1) else it }
        return markers.fold(joined) { text, marker -> marker.replace(text, "$1") }.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
    }
}

internal fun pushKey(userId: String, roomId: String, eventId: String): String = MessageDigest.getInstance("SHA-256")
    .digest("$userId\u0000$roomId\u0000$eventId".toByteArray()).joinToString("") { "%02x".format(it) }
