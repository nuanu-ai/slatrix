package ai.nuanu.slatrix

import ai.nuanu.slatrix.ui.mockups.SlatrixMockups
import android.app.Application
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTextInput
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
    @Test fun threadReplyPreservesTheChannelDraft() {
        compose.setContent { SlatrixMockups() }
        compose.onNodeWithText("design").performClick()
        compose.onNodeWithText("Message #design").performTextInput("Channel draft")
        compose.onNodeWithText("3 replies").performScrollTo().performClick()
        compose.onNodeWithText("Reply…").performTextInput("Looks ready.")
        compose.onNodeWithContentDescription("Send reply").performClick()
        compose.onNodeWithText("Looks ready.").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Channel draft").assertIsDisplayed()
        compose.onNodeWithContentDescription("Send message").performClick()
        compose.onNodeWithText("Channel draft").assertIsDisplayed()
        compose.onNodeWithText("Message #design").assertIsDisplayed()
    }
    @Test fun sentMessagesAndRepliesSurviveActivityRecreation() {
        val restoration = StateRestorationTester(compose)
        restoration.setContent { SlatrixMockups() }
        compose.onNodeWithText("design").performClick()
        compose.onNodeWithText("Message #design").performTextInput("Keep this message")
        compose.onNodeWithContentDescription("Send message").performClick()
        compose.onNodeWithText("3 replies").performScrollTo().performClick()
        compose.onNodeWithText("Reply…").performTextInput("Keep this reply")
        compose.onNodeWithContentDescription("Send reply").performClick()
        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithText("Keep this reply").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Keep this message").performScrollTo().assertIsDisplayed()
    }
    @Test fun activityFiltersAndReturnsFromItsThread() {
        compose.setContent { SlatrixMockups() }
        compose.onNodeWithText("Activity").performClick()
        compose.onNodeWithText("All").assertIsDisplayed()
        compose.onNodeWithText("Mentions").performClick()
        compose.onNodeWithText("Sam Taylor").assertDoesNotExist()
        compose.onNodeWithText("Threads").performClick()
        compose.onNodeWithText("Sam Taylor").performClick()
        compose.onNodeWithText("Thread").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Threads").assertIsSelected()
    }
    // Robolectric text-field dialogs loop with wider window qualifiers: robolectric/robolectric#8460.
    @Config(qualifiers = "w320dp-h892dp-420dpi")
    @Test fun statusEditingUsesAnOverlayAndCancelKeepsTheSavedStatus() {
        compose.setContent { SlatrixMockups() }
        compose.onNodeWithContentDescription("You").performClick()
        compose.onNodeWithText("Update your status").performClick()
        compose.onNode(isDialog()).assertExists()
        compose.onNode(hasSetTextAction()).performTextInput("Reviewing designs")
        compose.onNodeWithText("Save").performClick()
        compose.onNodeWithText("Reviewing designs").performClick()
        compose.onNode(hasSetTextAction()).performTextReplacement("Unsaved change")
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Reviewing designs").assertIsDisplayed()
        compose.onNodeWithText("Unsaved change").assertDoesNotExist()
    }
    @Test fun appearanceSettingsOpenFromYouAndBackReturnsToProfile() {
        compose.setContent { SlatrixMockups() }
        compose.onNodeWithContentDescription("You").performClick()
        compose.onNodeWithText("Preferences").performClick()
        compose.onNodeWithText("Dark mode").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithText("Jordan Lee").assertIsDisplayed()
        compose.onNodeWithText("Preferences").assertIsDisplayed()
    }
    @Test fun youChangesAndRetainsTheAppearance() {
        compose.setContent { SlatrixMockups() }
        compose.onNodeWithContentDescription("You").performClick()
        compose.onNodeWithText("Jordan Lee").assertIsDisplayed()
        compose.onNodeWithText("Preferences").performClick()
        compose.onNodeWithText("Dark mode").performScrollTo().performClick().assertIsOn()
        compose.onNodeWithText("Lagoon").performScrollTo().performClick().assertIsSelected()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithContentDescription("Back").performClick()
        compose.onNodeWithContentDescription("You").performClick()
        compose.onNodeWithText("Preferences").performClick()
        compose.onNodeWithText("Dark mode").assertIsOn()
        compose.onNodeWithText("Lagoon").assertIsSelected()
    }
}
