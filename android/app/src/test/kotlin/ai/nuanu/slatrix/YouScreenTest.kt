package ai.nuanu.slatrix

import ai.nuanu.slatrix.ui.account.LiveYouScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.TextLayoutResult
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w320dp-h704dp-xxxhdpi")
class YouScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test fun aLongMatrixIdStaysOnOneLineOnANarrowPhone() {
        val id = "@alexandra.doe-whitfield:matrix.harbor-collective.example.org"
        compose.setContent { SlatrixTheme { LiveYouScreen(id, { "Alexandra" }, {}, {}, onBack = {}) } }
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText(id, substring = true, useUnmergedTree = true).fetchSemanticsNode()
            .config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(layouts)
        assertEquals(1, layouts.single().lineCount)
    }
}
