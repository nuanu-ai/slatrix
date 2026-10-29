package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.Person
import ai.nuanu.slatrix.core.PeopleSearchState
import ai.nuanu.slatrix.ui.account.NewMessageScreen
import ai.nuanu.slatrix.ui.account.PersonProfileScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureScreenRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Renders someone's profile with fictional data for visual review, at the size of the Slack reference captures. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class PeopleScreenshots(private val screen: String, private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        compose.setContent {
            SlatrixTheme(dark = dark) {
                val colors = SlatrixTheme.colors
                Column {
                    Box(Modifier.fillMaxWidth().height(48.8.dp).background(colors.canvas))
                    Box(Modifier.weight(1f)) {
                        when (screen) {
                            "Profile" -> PersonProfileScreen(Person("@wanda:example.org", "Wanda Moss"), own = false, opening = false,
                                error = null, onMessage = {}, onBack = {})
                            "NewMessage" -> NewMessageScreen(PeopleSearchState("sam", listOf(Person("@sam:example.org", "Sam Lee"),
                                Person("@samira:example.org", "Samira Okafor"), Person("@sam.b:example.org", "Sam Brook"))), emptyList(), null, null,
                                {}, {}, {}, {})
                        }
                    }
                    Box(Modifier.fillMaxWidth().height(24.dp).background(colors.canvas))
                }
            }
        }
        if (screen == "NewMessage") compose.onNode(hasSetTextAction()).performTextInput("sam")
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/People-$screen-${if (dark) "dark" else "light"}.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "{0}-{1}")
        fun cases(): List<Array<Any>> = listOf("Profile", "NewMessage").flatMap { screen -> listOf(false, true).map { arrayOf(screen, it) } }
    }
}
