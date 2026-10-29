package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.ui.account.SignInScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class SignInScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun sendsEnteredCredentialsOnlyWhenTheFormIsComplete() {
        var submitted: List<String>? = null
        compose.setContent {
            SlatrixTheme {
                SignInScreen(connecting = false, error = null,
                    onSignIn = { server, user, password -> submitted = listOf(server, user, password) },
                    onCancel = {}, onRetryRestore = null)
            }
        }
        compose.onNodeWithText("Sign in", useUnmergedTree = true).assertIsNotEnabled()
        compose.onNodeWithText("Homeserver").performTextInput("matrix.example.org")
        compose.onNodeWithText("Username").performTextInput("alice")
        compose.onNodeWithText("Password").performTextInput("  secret  ")
        compose.onNodeWithText("Sign in", useUnmergedTree = true).performClick()
        compose.runOnIdle { assertEquals(listOf("matrix.example.org", "alice", "  secret  "), submitted) }
    }
}
