package ai.nuanu.slatrix.push

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class PushMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val roomId = message.data["room_id"] ?: return
        val eventId = message.data["event_id"] ?: return
        if (!roomId.startsWith('!') || !eventId.startsWith('$') ||
            listOf(roomId, eventId).any { it.length > 1024 || it.any(Char::isISOControl) }) return
        PushNotificationWorker.enqueue(this, roomId, eventId, message.priority == RemoteMessage.PRIORITY_HIGH)
    }

    override fun onNewToken(token: String) {
        runCatching { PushRegistration(this).updateToken(token) }
        PushRegistrationWorker.enqueue(this)
    }
}
