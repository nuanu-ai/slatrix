package ai.nuanu.slatrix.push

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.WorkManager
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.*
import org.robolectric.RobolectricTestRunner
import org.robolectric.Robolectric
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class PushRegistrationTest {
    @Test fun firebaseTokenRotationReplacesTheRegisteredPusher() = runTest {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val server = PusherClient()
        val registration = PushRegistration(context)
        registration.updateToken("previous-token")
        registration.register(server, "@alex:example.org", "https://push.example.org/_matrix/push/v1/notify")
        try {
            WorkManager.getInstance(context)
        } catch (_: IllegalStateException) {
            WorkManager.initialize(context, Configuration.Builder().build())
        }
        val service = Robolectric.buildService(PushMessagingService::class.java).create().get()

        service.onNewToken("firebase-refreshed-token")
        PushRegistration(context).register(server, "@alex:example.org", "https://push.example.org/_matrix/push/v1/notify")

        assertEquals(setOf("firebase-refreshed-token"), server.pushers.keys)
    }

    @Test fun rotatingTheTokenPreservesDeliveryUntilReplacementAndResumesCleanupAfterReopening() = runTest {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val registration = PushRegistration(context)
        val server = PusherClient()
        registration.updateToken("original-token")
        registration.register(server, "@alex:example.org", "https://push.example.org/_matrix/push/v1/notify")
        registration.updateToken("rotated-token")
        server.rejectRegistration = true

        assertTrue(runCatching {
            registration.register(server, "@alex:example.org", "https://push.example.org/_matrix/push/v1/notify")
        }.isFailure)
        assertEquals(setOf("original-token"), server.pushers.keys)

        server.rejectRegistration = false
        server.rejectDeletion = true
        assertTrue(runCatching {
            registration.register(server, "@alex:example.org", "https://push.example.org/_matrix/push/v1/notify")
        }.isFailure)
        assertEquals(setOf("original-token", "rotated-token"), server.pushers.keys)

        server.rejectDeletion = false
        PushRegistration(context).register(server, "@alex:example.org", "https://push.example.org/_matrix/push/v1/notify")
        assertEquals(setOf("rotated-token"), server.pushers.keys)
        val pusher = server.pushers.getValue("rotated-token")
        assertEquals(context.packageName, pusher.first.appId)
        assertEquals(PusherKind.Http(HttpPusherData("https://push.example.org/_matrix/push/v1/notify", PushFormat.EVENT_ID_ONLY, null)), pusher.second)
    }
}

private class PusherClient : Client(NoHandle) {
    val pushers = mutableMapOf<String, Pair<PusherIdentifiers, PusherKind>>()
    var rejectRegistration = false
    var rejectDeletion = false
    override suspend fun setPusher(identifiers: PusherIdentifiers, kind: PusherKind, appDisplayName: String,
        deviceDisplayName: String, profileTag: String?, lang: String, append: Boolean) {
        check(!rejectRegistration)
        pushers[identifiers.pushkey] = identifiers to kind
    }
    override suspend fun deletePusher(identifiers: PusherIdentifiers) {
        check(!rejectDeletion)
        pushers.remove(identifiers.pushkey)
    }
}
