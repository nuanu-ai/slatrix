package ai.nuanu.slatrix

import android.app.Application
import android.view.WindowInsetsController
import ai.nuanu.slatrix.core.AppearancePreferences
import ai.nuanu.slatrix.core.MatrixAccount
import ai.nuanu.slatrix.core.SessionStore
import ai.nuanu.slatrix.ui.account.SlatrixApp
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.core.app.ApplicationProvider
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.OAuthConfiguration
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-notnight-420dpi")
class WindowAppearanceTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val lightBars = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
        WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS

    @Test fun aSavedDarkChoiceOverridesALightSystem() = checkAppearance(saved = true, bars = 0)

    @Test @Config(qualifiers = "w412dp-h892dp-night-420dpi")
    fun aSavedLightChoiceOverridesADarkSystem() = checkAppearance(saved = false, bars = lightBars)

    @Test @Config(qualifiers = "w412dp-h892dp-night-420dpi")
    fun withoutAChoiceTheAppFollowsADarkSystem() = checkAppearance(saved = null, bars = 0)

    private fun checkAppearance(saved: Boolean?, bars: Int) {
        val context = ApplicationProvider.getApplicationContext<Application>()
        AppearancePreferences(context).darkMode = saved
        val scope = CoroutineScope(SupervisorJob())
        val account = MatrixAccount(scope, SessionStore(context), File(context.noBackupFilesDir, "matrix"),
            OAuthConfiguration("Slatrix", "com.github.nuanu-ai.slatrix.dev:/oauth/callback", "https://github.com/nuanu-ai/slatrix",
                null, null, null, emptyMap()))
        try {
            compose.setContent { SlatrixApp(account, null, null, null) }
            compose.runOnIdle {
                assertEquals(bars, compose.activity.window.insetsController!!.systemBarsAppearance and lightBars)
            }
        } finally {
            scope.cancel()
        }
    }
}
