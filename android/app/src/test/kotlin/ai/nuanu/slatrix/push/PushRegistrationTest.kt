package ai.nuanu.slatrix.push

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.WorkManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
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
    @Test fun aStaleFirebaseTokenLookupCannotOverwriteANewerTokenCallback() = runTest {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val registration = PushRegistration(context)
        val server = PusherClient()
        val lookupVersion = registration.tokenVersion

        registration.updateToken("new-callback-token")
        registration.updateToken("stale-lookup-token", expectedVersion = lookupVersion)
        registration.register(server, "@stale-response:example.org", "https://push.example.org/_matrix/push/v1/notify")

        assertEquals(setOf("new-callback-token"), server.pushers.keys)
    }

    @Test fun rotationDuringRegistrationLeavesOnlyTheNewestTokenRegistered() = runTest {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val registration = PushRegistration(context)
        val server = PusherClient()
        val registering = CompletableDeferred<Unit>()
        val response = CompletableDeferred<Unit>()
        server.registering = { token ->
            if (token == "in-flight-token") {
                registering.complete(Unit)
                response.await()
            }
        }
        registration.updateToken("in-flight-token")
        val pending = async {
            registration.register(server, "@during-rotation:example.org", "https://push.example.org/_matrix/push/v1/notify")
        }
        registering.await()
        registration.updateToken("latest-callback-token")
        response.complete(Unit)
        pending.await()

        assertEquals(setOf("latest-callback-token"), server.pushers.keys)
    }

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

    @Test fun everyConnectionRestoresAPusherTheServerDropped() = runTest {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val server = PusherClient()
        val registration = PushRegistration(context)
        registration.updateToken("registered-token")
        registration.register(server, "@alex:example.org", "https://push.example.org/_matrix/push/v1/notify")
        server.pushers.clear()

        registration.register(server, "@alex:example.org", "https://push.example.org/_matrix/push/v1/notify")
        assertEquals(setOf("registered-token"), server.pushers.keys)
    }

    @Test fun signingOutRemovesTheCurrentAndRotatedPushers() = runTest {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val server = PusherClient()
        val registration = PushRegistration(context)
        registration.updateToken("original-token")
        registration.register(server, "@alex:example.org", "https://push.example.org/_matrix/push/v1/notify")
        registration.updateToken("rotated-token")
        server.rejectDeletion = true
        runCatching { registration.register(server, "@alex:example.org", "https://push.example.org/_matrix/push/v1/notify") }
        server.rejectDeletion = false

        registration.unregister(server, "@alex:example.org")
        assertEquals(emptySet<String>(), server.pushers.keys)
    }
}

private class PusherClient : Client(NoHandle) {
    val pushers = mutableMapOf<String, Pair<PusherIdentifiers, PusherKind>>()
    var registering: suspend (String) -> Unit = {}
    var rejectRegistration = false
    var rejectDeletion = false
    override suspend fun setPusher(identifiers: PusherIdentifiers, kind: PusherKind, appDisplayName: String,
        deviceDisplayName: String, profileTag: String?, lang: String, append: Boolean) {
        check(!rejectRegistration)
        registering(identifiers.pushkey)
        pushers[identifiers.pushkey] = identifiers to kind
    }
    override suspend fun deletePusher(identifiers: PusherIdentifiers) {
        check(!rejectDeletion)
        pushers.remove(identifiers.pushkey)
    }
}
