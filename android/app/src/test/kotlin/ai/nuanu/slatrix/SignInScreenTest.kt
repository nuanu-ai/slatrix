package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.ui.account.SignInMethodsScreen
import ai.nuanu.slatrix.core.SignInOptions
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
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
                SignInMethodsScreen(options = SignInOptions("https://matrix.example.org", true, false, false), connecting = false, error = null,
                    onSignIn = { user, password -> submitted = listOf(user, password) }, onBrowser = {}, onBack = {})
            }
        }
        compose.onNode(hasText("Sign in") and hasClickAction()).assertIsNotEnabled()
        compose.onNodeWithText("Username").performTextInput("alice")
        compose.onNodeWithText("Password").performTextInput("  secret  ")
        compose.onNode(hasText("Sign in") and hasClickAction()).performClick()
        compose.runOnIdle { assertEquals(listOf("alice", "  secret  "), submitted) }
    }
}
