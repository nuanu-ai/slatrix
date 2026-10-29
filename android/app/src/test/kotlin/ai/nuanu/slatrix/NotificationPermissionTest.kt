package ai.nuanu.slatrix

import android.Manifest
import android.app.Application
import ai.nuanu.slatrix.ui.account.RequestNotificationPermission
import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35])
class NotificationPermissionTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun aBuildWithoutPushConfigurationDoesNotRequestNotificationPermission() {
        compose.setContent { RequestNotificationPermission(signedIn = true, configured = false) }
        compose.runOnIdle { assertNull(shadowOf(compose.activity).lastRequestedPermission) }
    }

    @Test @Config(sdk = [32])
    fun olderAndroidDoesNotRequestTheNewRuntimePermission() {
        compose.setContent { RequestNotificationPermission(signedIn = true, configured = true) }
        compose.runOnIdle { assertNull(shadowOf(compose.activity).lastRequestedPermission) }
    }

    @Test fun notificationPermissionWaitsUntilTheUserHasSignedIn() {
        val application = ApplicationProvider.getApplicationContext<Application>()
        shadowOf(application).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val signedIn = mutableStateOf(false)
        compose.setContent { RequestNotificationPermission(signedIn.value, configured = true) }

        compose.runOnIdle { assertNull(shadowOf(compose.activity).lastRequestedPermission) }
        compose.runOnIdle { signedIn.value = true }
        compose.waitUntil { shadowOf(compose.activity).lastRequestedPermission != null }
        compose.runOnIdle {
            assertArrayEquals(arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                shadowOf(compose.activity).lastRequestedPermission.requestedPermissions)
        }
    }
}
