package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.Invitation
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.InvitationScreen
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
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

/** Renders Home with invitations and an invitation's page, with fictional data, at the reference captures' size. */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class InvitationScreenshots(private val screen: String, private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        val design = Invitation("!design:example.org", "design", inviter = "Wanda Moss")
        val invitations = listOf(design, Invitation("!dev:example.org", "Dev Singh", direct = true, inviter = "Dev Singh"),
            Invitation("!harbor:example.org", "Harbor", space = true, inviter = "Nina"))
        val rooms = listOf(RoomSummary("!general:example.org", "general", false, "", UnreadBadge.None, "G", 2),
            RoomSummary("!wm:example.org", "Wanda Moss", true, "", UnreadBadge.None, "WM", 1))
        compose.setContent {
            SlatrixTheme(dark = dark) {
                val colors = SlatrixTheme.colors
                Column {
                    Box(Modifier.fillMaxWidth().height(48.8.dp).background(if (screen == "Home") colors.workspaceBar else colors.canvas))
                    Box(Modifier.weight(1f)) {
                        when (screen) {
                            "Home" -> LiveHomeScreen("@alex:example.org", RoomListState(rooms, loading = false, spacesKnown = true,
                                invitations = invitations), {}, {}, {})
                            "Invitation" -> InvitationScreen(design, responding = false, error = null, onJoin = {}, onDecline = {}, onBack = {})
                        }
                    }
                    Box(Modifier.fillMaxWidth().height(24.dp).background(if (screen == "Home") colors.raised else colors.canvas))
                }
            }
        }
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/Invitations-$screen-${if (dark) "dark" else "light"}.png")
    }

    companion object {
        @JvmStatic @Parameters(name = "{0}-{1}")
        fun cases(): List<Array<Any>> = listOf("Home", "Invitation").flatMap { screen -> listOf(false, true).map { arrayOf(screen, it) } }
    }
}
