package ai.nuanu.slatrix

import ai.nuanu.slatrix.ui.mockups.SlatrixMockups
import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class MockNavigationTest {
    @get:Rule val compose = createComposeRule()

    @Test fun homeOpensChannelAndBackRestoresHome() {
        compose.setContent { SlatrixMockups() }
        compose.onNodeWithText("design").performClick()
        compose.onNodeWithText("Message #design").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Channels").assertIsDisplayed()
    }
    @Test fun dmsOpenTheSelectedConversation() {
        compose.setContent { SlatrixMockups() }
        compose.onNodeWithText("DMs").performClick()
        compose.onNodeWithText("Ava Patel").assertIsDisplayed().performClick()
        compose.onNodeWithText("Message Ava Patel").assertIsDisplayed()
        compose.onNodeWithText("Love this direction.", substring = true).assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Ava Patel").assertIsDisplayed()
    }
}
