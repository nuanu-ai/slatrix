package ai.nuanu.slatrix.ui.designsystem

import android.app.Application
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.font.FontWeight
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class TypefaceTest {
    @get:Rule val compose = createComposeRule()

    /** Slack sets its text in Lato with no added tracking. The widths come from Lato 2.015's advance widths at 16 sp. */
    @Test fun theTypeScaleSetsTextInLatoAsSlackDoes() {
        compose.setContent {
            SlatrixTheme {
                Text("Direct messages", style = MaterialTheme.typography.bodyLarge)
                Text("Starred", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
            }
        }
        val density = compose.onNodeWithText("Direct messages").fetchSemanticsNode().layoutInfo.density.density
        fun width(text: String) = compose.onNodeWithText(text).fetchSemanticsNode().size.width / density
        assertEquals(114.9f, width("Direct messages"), 1f)
        assertEquals(52.4f, width("Starred"), 1f)
    }
}
