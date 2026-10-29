package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ComposerStyle
import ai.nuanu.slatrix.core.ComposerStyle.Kind
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ComposerActions
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextInputSelection
import androidx.compose.ui.text.TextRange
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
class ComposerFormattingScreenTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
    private val text = mutableStateOf("Hi there")
    private val styles = mutableStateOf(emptyList<ComposerStyle>())
    private val formats = mutableListOf<Format>()

    private data class Format(val start: Int, val end: Int, val kind: Kind, val href: String?)

    private fun show() {
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(emptyList(), loading = false, hasMore = false),
                    ComposerState(text.value, loading = false, styles = styles.value), { text.value = it }, {}, {}, {}, {}, {}, {}, {},
                    composerActions = ComposerActions(onFormat = { start, end, kind, href -> formats += Format(start, end, kind, href) }))
            }
        }
    }

    // capability: composer.formatting
    @Test fun aaShowsSlacksFormatsAndEachAppliesToTheSelection() {
        show()
        compose.onNodeWithContentDescription("Message #design").performTextInputSelection(TextRange(3, 8))
        compose.onNodeWithContentDescription("Formatting").performClick()
        val kinds = listOf("Bold" to Kind.Bold, "Italic" to Kind.Italic, "Strikethrough" to Kind.Strike, "Code" to Kind.Code,
            "Bulleted list" to Kind.Bullet, "Numbered list" to Kind.Numbered, "Quote" to Kind.Quote, "Code block" to Kind.CodeBlock)
        for ((label, _) in kinds) compose.onNodeWithContentDescription(label).performScrollTo().performClick()
        compose.runOnIdle { assertEquals(kinds.map { Format(3, 8, it.second, null) }, formats) }
    }

    // capability: composer.formatting
    @Test fun linkAsksForTheAddressAndLinksTheSelection() {
        show()
        compose.onNodeWithContentDescription("Message #design").performTextInputSelection(TextRange(3, 8))
        compose.onNodeWithContentDescription("Formatting").performClick()
        compose.onNodeWithContentDescription("Link").performClick()
        compose.onNode(hasSetTextAction() and hasText("Link")).performTextInput("example.org/docs")
        compose.onNodeWithText("Save").performClick()
        compose.runOnIdle { assertEquals(listOf(Format(3, 8, Kind.Link, "https://example.org/docs")), formats) }
    }

    @Test fun linkWithNothingSelectedAddsItsTextWhereYouType() {
        text.value = "See "
        show()
        compose.onNodeWithContentDescription("Message #design").performTextInputSelection(TextRange(4))
        compose.onNodeWithContentDescription("Formatting").performClick()
        compose.onNodeWithContentDescription("Link").performClick()
        compose.onNode(hasSetTextAction() and hasText("Text")).performTextInput("docs")
        compose.onNode(hasSetTextAction() and hasText("Link")).performTextInput("https://example.org")
        compose.onNodeWithText("Save").performClick()
        compose.runOnIdle {
            assertEquals("See docs", text.value)
            assertEquals(listOf(Format(4, 8, Kind.Link, "https://example.org")), formats)
        }
    }

    @Test fun anAddressThatCannotBeALinkCannotBeSaved() {
        show()
        compose.onNodeWithContentDescription("Message #design").performTextInputSelection(TextRange(3, 8))
        compose.onNodeWithContentDescription("Formatting").performClick()
        compose.onNodeWithContentDescription("Link").performClick()
        compose.onNode(hasSetTextAction() and hasText("Link")).performTextInput("javascript:alert(1)")
        compose.onNodeWithText("Save").assertIsNotEnabled()
    }

    @Test fun aLinkOpensWithItsAddressAndAnEmptyAddressRemovesIt() {
        text.value = "See docs"
        styles.value = listOf(ComposerStyle(4, 8, Kind.Link, "https://example.org"))
        show()
        compose.onNodeWithContentDescription("Message #design").performTextInputSelection(TextRange(6))
        compose.onNodeWithContentDescription("Formatting").performClick()
        compose.onNodeWithContentDescription("Link").performClick()
        compose.onNode(hasSetTextAction() and hasText("https://example.org")).performTextClearance()
        compose.onNodeWithText("Save").performClick()
        compose.runOnIdle { assertEquals(listOf(Format(4, 8, Kind.Link, "")), formats) }
    }

    // capability: composer.formatting
    @Test fun returnOnAnEmptyListItemEndsTheListInsteadOfAddingALine() {
        text.value = "one\n"
        styles.value = listOf(ComposerStyle(0, 4, Kind.Bullet))
        show()
        compose.onNodeWithContentDescription("Message #design").performTextInputSelection(TextRange(4))
        compose.onNodeWithContentDescription("Message #design").performTextInput("\n")
        compose.runOnIdle {
            assertEquals(listOf(Format(4, 4, Kind.Bullet, null)), formats)
            assertEquals("one\n", text.value)
        }
    }
}
