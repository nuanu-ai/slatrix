package ai.nuanu.slatrix

import android.app.Application
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class SignInActivityTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun aNewInstallationAsksForTheServerBeforeCredentials() {
        compose.onNodeWithText("Homeserver").assertExists()
        compose.onNodeWithText("Continue").assertExists()
        compose.onNodeWithText("Username").assertDoesNotExist()
        compose.onNodeWithText("Password").assertDoesNotExist()
    }
}
