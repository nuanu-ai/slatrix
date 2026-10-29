package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.ui.account.SignInMethodsScreen
import ai.nuanu.slatrix.core.SignInOptions
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.core.AccountState
import ai.nuanu.slatrix.core.MatrixAccount
import ai.nuanu.slatrix.core.SessionStore
import ai.nuanu.slatrix.ui.account.SlatrixApp
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.onAllNodesWithText
import androidx.test.core.app.ApplicationProvider
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertFalse
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.HomeserverLoginDetails
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.OAuthConfiguration
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

    @Test fun backFromAFailedSignInReturnsToServerChoiceInsteadOfLeavingTheApp() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val scope = CoroutineScope(SupervisorJob())
        val client = object : Client(NoHandle) {
            override suspend fun homeserverLoginDetails(): HomeserverLoginDetails = object : HomeserverLoginDetails(NoHandle) {
                override fun url() = "https://matrix.example.org"
                override fun supportsPasswordLogin() = true
                override fun supportsSsoLogin() = false
                override fun supportsOauthLogin() = false
            }
            override suspend fun login(username: String, password: String, initialDeviceName: String?, deviceId: String?) =
                error("fictional rejected password")
        }
        val account = MatrixAccount(scope, SessionStore(context), File(context.noBackupFilesDir, "matrix"),
            OAuthConfiguration("Slatrix", "com.github.nuanu-ai.slatrix.dev:/oauth/callback", "https://github.com/nuanu-ai/slatrix",
                null, null, null, emptyMap())) { _, _, _, _, _ -> client }
        compose.setContent { SlatrixApp(account, null, null, null) }
        account.selectHomeserver("https://matrix.example.org")
        compose.waitUntil(5_000) { account.state.value is AccountState.ChooseMethod }
        account.signIn("alice", "wrong")
        compose.waitUntil(5_000) { account.state.value is AccountState.Failed }

        compose.runOnIdle { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.runOnIdle {
            assertFalse(compose.activity.isFinishing)
            assertEquals(AccountState.SignedOut, account.state.value)
        }
        scope.cancel()
    }

    @Test fun signingInAgainAfterAFailedRestoreForgetsTheSavedSession() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        val saved = File(context.noBackupFilesDir, "session.enc").apply { writeBytes("unreadable-session-fixture".toByteArray()) }
        val scope = CoroutineScope(SupervisorJob())
        val account = MatrixAccount(scope, SessionStore(context), File(context.noBackupFilesDir, "matrix"),
            OAuthConfiguration("Slatrix", "com.github.nuanu-ai.slatrix.dev:/oauth/callback", "https://github.com/nuanu-ai/slatrix",
                null, null, null, emptyMap()))
        compose.setContent { SlatrixApp(account, null, null, null) }
        account.restore()

        compose.waitUntil(5_000) { compose.onAllNodesWithText("Sign in again").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Sign in again").performClick()
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Homeserver").fetchSemanticsNodes().isNotEmpty() }
        assertFalse(saved.exists())
        scope.cancel()
    }
}
