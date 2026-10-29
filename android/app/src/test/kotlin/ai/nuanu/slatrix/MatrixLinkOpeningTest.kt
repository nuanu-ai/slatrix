package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ProvideMatrixLinks
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [35])
class MatrixLinkOpeningTest {
    @get:Rule val compose = createComposeRule()
    private val design = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)

    // capability: message.matrix-links
    @Test fun aLinkToAPersonOrToAConversationOrMessageYouAreInOpensHereAndAnythingElseGoesOn() {
        val opened = mutableListOf<Pair<String, String?>>()
        val browsed = mutableListOf<String>()
        val notices = mutableListOf<String>()
        val people = mutableListOf<String>()
        val links = listOf("https://matrix.to/#/!design:example.org/\$event", "matrix:r/design:example.org",
            "https://matrix.to/#/!elsewhere:example.org", "https://example.org/page", "https://matrix.to/#/invalid",
            "matrix:roomid/elsewhere:example.org", "https://matrix.to/#/%40sam%3Aexample.org", "matrix:u/quinn:example.org")
        compose.setContent {
            SlatrixTheme {
                CompositionLocalProvider(LocalUriHandler provides object : UriHandler { override fun openUri(uri: String) { browsed += uri } }) {
                    ProvideMatrixLinks({ listOf(design) }, { alias -> "!design:example.org".takeIf { alias == "#design:example.org" } },
                        { room, event -> opened += room.id to event }, { people += it }, { notices += it }) {
                        val handler = LocalUriHandler.current
                        Column { links.forEach { link -> TextButton({ handler.openUri(link) }) { Text(link) } } }
                    }
                }
            }
        }
        links.forEach { compose.onNodeWithText(it).performClick() }

        compose.runOnIdle {
            assertEquals(listOf("!design:example.org" to "\$event", "!design:example.org" to null), opened)
            assertEquals("A conversation you're not in, and other sites, open in the browser",
                // A browser can't open a matrix: URI, so it gets the matrix.to link instead.
                listOf("https://matrix.to/#/!elsewhere:example.org", "https://example.org/page", "https://matrix.to/#/!elsewhere:example.org"),
                browsed)
            assertEquals(listOf("Slatrix can’t open this link."), notices)
            assertEquals("A person opens their profile here", listOf("@sam:example.org", "@quinn:example.org"), people)
        }
    }
}
