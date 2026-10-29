package ai.nuanu.slatrix

import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.mockups.MockScreen
import ai.nuanu.slatrix.ui.mockups.SlatrixMockups
import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class MockScreenshots(
    private val screen: MockScreen,
    private val dark: Boolean,
    private val palette: SidebarPalette,
    private val fontScale: Float,
) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        compose.setContent {
            val density = LocalDensity.current.density
            CompositionLocalProvider(LocalDensity provides Density(density, fontScale)) {
                SlatrixMockups(dark = dark)
            }
        }
        if (palette == SidebarPalette.Lagoon) {
            compose.onNodeWithContentDescription("You").performClick()
            compose.onNodeWithText("Preferences").performClick()
            compose.onNodeWithText("Lagoon").performScrollTo().performClick()
            compose.onNodeWithContentDescription("Back").performClick()
            compose.onNodeWithContentDescription("Back").performClick()
        }
        when (screen) {
            MockScreen.Home -> Unit
            MockScreen.Dms -> compose.onNodeWithText("DMs").performClick()
            MockScreen.Activity -> compose.onNodeWithText("Activity").performClick()
            MockScreen.Channel -> compose.onNodeWithText("design").performClick()
            MockScreen.Thread -> compose.onNodeWithText("Threads").performClick()
            MockScreen.You -> compose.onNodeWithContentDescription("You").performClick()
        }
        val landmark = when (screen) {
            MockScreen.Home -> "Channels"
            MockScreen.Dms -> "Ava Patel"
            MockScreen.Activity -> "All"
            MockScreen.Channel -> "Message #design"
            MockScreen.Thread -> "Reply…"
            MockScreen.You -> "Jordan Lee"
        }
        compose.onNodeWithText(landmark).assertIsDisplayed()
        val theme = if (dark) "dark" else "light"
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/${screen.name}-$theme-${palette.tokenName}-$fontScale.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "{0}-{1}-{2}-font{3}")
        fun cases(): List<Array<Any>> = buildList {
            for (screen in MockScreen.entries) {
                for (dark in listOf(false, true)) {
                    for (palette in listOf(SidebarPalette.Aubergine, SidebarPalette.Lagoon)) {
                        add(arrayOf(screen, dark, palette, 1f))
                    }
                    add(arrayOf(screen, dark, SidebarPalette.Aubergine, 1.3f))
                }
            }
        }
    }
}
