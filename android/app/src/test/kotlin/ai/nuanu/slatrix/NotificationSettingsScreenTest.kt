package ai.nuanu.slatrix

import android.app.Application
import ai.nuanu.slatrix.core.NotifyAbout
import ai.nuanu.slatrix.ui.account.LivePreferencesScreen
import ai.nuanu.slatrix.ui.account.LiveNotificationSettings
import ai.nuanu.slatrix.ui.account.NotificationRows
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import androidx.activity.ComponentActivity
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.matrix.rustcomponents.sdk.ClientException
import org.matrix.rustcomponents.sdk.NoHandle
import org.matrix.rustcomponents.sdk.NotificationSettings
import org.matrix.rustcomponents.sdk.RoomNotificationMode
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class NotificationSettingsScreenTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    // capability: notifications.defaults
    // capability: notifications.previews
    @Test fun preferencesChooseWhatNotifiesAndWhetherAlertsShowMessageText() {
        val notifyAbout = mutableStateOf<NotifyAbout?>(NotifyAbout.All)
        val previews = mutableStateOf(true)
        compose.setContent {
            SlatrixTheme {
                LivePreferencesScreen(false, null, SidebarPalette.Aubergine, {}, {}, {}) {
                    NotificationRows(notifyAbout.value, previews.value, null, { notifyAbout.value = it }, { previews.value = it })
                }
            }
        }
        compose.onNodeWithText("All new messages").assertExists()
        compose.onNodeWithText("Notify me about").performClick()
        compose.onNode(hasText("All new messages") and isSelected()).assertExists()
        compose.onNodeWithText("Direct messages, mentions & keywords").performClick()
        compose.runOnIdle { assertEquals(NotifyAbout.DirectAndMentions, notifyAbout.value) }
        compose.onNodeWithText("Nothing").assertDoesNotExist()

        compose.onNodeWithText("Show message previews").assertIsOn().performClick()
        compose.runOnIdle { assertEquals(false, previews.value) }
        compose.onNodeWithText("Show message previews").assertIsOff()
    }

    @Test fun aChoiceTheServerRefusesGoesBackAndSaysSo() {
        val rules = object : NotificationSettings(NoHandle) {
            override suspend fun getDefaultRoomNotificationMode(isEncrypted: Boolean, isOneToOne: Boolean) = RoomNotificationMode.ALL_MESSAGES
            override suspend fun setDefaultRoomNotificationMode(isEncrypted: Boolean, isOneToOne: Boolean, mode: RoomNotificationMode) =
                throw ClientException.Generic("offline", null)
        }
        compose.setContent { SlatrixTheme { LiveNotificationSettings { rules } } }
        compose.onNodeWithText("All new messages").assertExists()
        compose.onNodeWithText("Notify me about").performClick()
        compose.onNodeWithText("Direct messages, mentions & keywords").performClick()
        compose.onNodeWithText("Couldn't save. Try again.").assertExists()
        compose.onNodeWithText("Notify me about").performClick()
        compose.onNode(hasText("All new messages") and isSelected()).assertExists()
    }
}
