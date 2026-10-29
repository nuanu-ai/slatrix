package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ChannelDirectoryState
import ai.nuanu.slatrix.core.DirectoryChannel
import ai.nuanu.slatrix.ui.account.BrowseChannelsScreen
import ai.nuanu.slatrix.ui.account.CreateChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.ui.Modifier
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

/** Renders Browse channels and Create a channel with fictional data for visual review, at the reference captures' size. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class ChannelScreenshots(private val screen: String, private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val channels = listOf(
            DirectoryChannel("!design:example.org", "design", "Reviews, crits and the weekly show-and-tell", 12, canJoin = true),
            DirectoryChannel("!general:example.org", "general", "Company-wide news", 48, canJoin = true),
            DirectoryChannel("!launch:example.org", "launch-plans", null, 7, canJoin = true),
            DirectoryChannel("!board:example.org", "board", null, 3, canJoin = false, rule = "Invite only"),
        )
        compose.setContent {
            SlatrixTheme(dark = dark) {
                val colors = SlatrixTheme.colors
                Column {
                    Box(Modifier.fillMaxWidth().height(48.8.dp).background(colors.canvas))
                    Box(Modifier.weight(1f)) {
                        when (screen) {
                            "Browse" -> BrowseChannelsScreen("Browse channels", ChannelDirectoryState(channels), setOf("!general:example.org"),
                                null, null, {}, {}, {}, {})
                            "Create" -> CreateChannelScreen("Harbor", creating = false, error = null, onCreate = { _, _ -> }, onBack = {})
                        }
                    }
                    Box(Modifier.fillMaxWidth().height(24.dp).background(colors.canvas))
                }
            }
        }
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/Channels-$screen-${if (dark) "dark" else "light"}.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "{0}-{1}")
        fun cases(): List<Array<Any>> = listOf("Browse", "Create").flatMap { screen -> listOf(false, true).map { arrayOf(screen, it) } }
    }
}
