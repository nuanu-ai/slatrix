package ai.nuanu.slatrix.push

import com.google.firebase.messaging.FirebaseMessagingService

class PushMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        runCatching { PushRegistration(this).updateToken(token) }
        PushRegistrationWorker.enqueue(this)
    }
}
