package ai.nuanu.slatrix.push

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
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
    val enabled: Boolean get() = manager.areNotificationsEnabled() && (Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

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
        val title = if (body != null) item?.roomInfo?.displayName?.takeIf { it.isNotBlank() } ?: "Slatrix" else "Slatrix"
        val sender = if (body != null) item?.senderInfo?.displayName?.takeIf { it.isNotBlank() } ?: event?.senderId() else null
        val text = if (body == null) "New message" else if (item?.roomInfo?.isDirect == true || sender == null) body else "$sender: $body"
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(CHANNEL, "Messages", NotificationManager.IMPORTANCE_DEFAULT))
        val intent = Intent(context, MainActivity::class.java)
            .setAction("${context.packageName}.OPEN_NOTIFICATION")
            .setData("slatrix://notification/$key".toUri())
            .putExtra(USER_ID, userId).putExtra(ROOM_ID, roomId).putExtra(EVENT_ID, eventId).putExtra(THREAD_ID, resolved?.threadId)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val tap = PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun builder() = NotificationCompat.Builder(context, CHANNEL).setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(tap).setAutoCancel(true).setDefaults(NotificationCompat.DEFAULT_SOUND)
        val publicNotification = builder().setContentTitle("Slatrix").setContentText("New message").build()
        val notification = builder().setContentTitle(title).setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(publicNotification)
            .setOnlyAlertOnce(true).setSilent(resolved?.isNoisy != true).build()
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context,
                Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return@synchronized
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

internal fun pushKey(userId: String, roomId: String, eventId: String): String = MessageDigest.getInstance("SHA-256")
    .digest("$userId\u0000$roomId\u0000$eventId".toByteArray()).joinToString("") { "%02x".format(it) }
