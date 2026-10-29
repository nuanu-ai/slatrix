package ai.nuanu.slatrix

import ai.nuanu.slatrix.ui.mockups.SlatrixMockups
import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class SlackRootsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun homeDirectMessageOpensTheSelectedConversation() {
        compose.setContent { SlatrixMockups() }

        compose.onNodeWithText("Ava Patel").performScrollTo().performClick()

        compose.onNodeWithText("Message Ava Patel").assertIsDisplayed()
        compose.onNodeWithText("Love this direction.", substring = true).assertIsDisplayed()
    }
}
