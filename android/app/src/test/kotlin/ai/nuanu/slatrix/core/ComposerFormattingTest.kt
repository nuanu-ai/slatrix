package ai.nuanu.slatrix.core

import ai.nuanu.slatrix.core.ComposerStyle.Kind
import com.google.gson.JsonParser
import java.io.File
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/** What the composer sends once text is formatted, checked against the shared cases in spec/composer.json. */
class ComposerFormattingTest {
    private val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "spec/composer.json").readText())
        .asJsonObject["send"].asJsonArray.map { it.asJsonObject }.associateBy { it["name"].asString }

    /** What a shared case says goes out. */
    private fun expected(name: String) = spec.getValue(name).let { case ->
        ComposerMessage(case["body"].asString, case["html"].takeUnless { it.isJsonNull }?.asString,
            case["mentions"].asJsonArray.map { it.asString }, case["mentionsRoom"].asBoolean)
    }

    private class Sending(scope: TestScope, room: ComposerRoom = ComposerRoom()) {
        val sent = Channel<ComposerMessage>(Channel.UNLIMITED)
        val composer = MatrixComposer(scope.backgroundScope, room) { sent.send(it); true }
        suspend fun send(): ComposerMessage {
            composer.send()
            val message = sent.receive()
            composer.state.first { !it.sending && it.text.isEmpty() }
            return message
        }
    }

    // capability: composer.formatting
    @Test fun eachFormatSendsTheSharedCasesHtml() = runTest {
        val sending = Sending(this)
        sending.composer.state.first { !it.loading }
        for (case in listOf(
            Case("Bold", "Hi there", 3, Kind.Bold),
            Case("Italic", "soft", 0, Kind.Italic),
            Case("Strikethrough", "gone", 0, Kind.Strike),
            Case("Inline code, with its body in backticks", "a < b", 0, Kind.Code),
            Case("A link, with its address after the text in the body", "docs", 0, Kind.Link, "https://example.org/a?b=1&c"),
            Case("A bulleted list", "one\ntwo", 0, Kind.Bullet),
            Case("A numbered list", "one\ntwo", 0, Kind.Numbered),
            Case("A quote, line by line", "said\nthis", 0, Kind.Quote),
            Case("A code block, fenced in the body", "if a < b {\n  go()", 0, Kind.CodeBlock),
        )) {
            sending.composer.edit(case.text)
            sending.composer.format(case.start, case.text.length, case.kind, case.href)
            assertEquals(case.name, expected(case.name), sending.send())
        }
    }

    // capability: composer.formatting
    @Test fun boldGoesOnASelectionAndOffAgainAndAtTheCaretAppliesToWhatIsTypedNext() = runTest {
        val sending = Sending(this)
        sending.composer.state.first { !it.loading }
        sending.composer.edit("Hi there")
        sending.composer.format(3, 8, Kind.Bold)
        sending.composer.format(3, 8, Kind.Bold)
        assertEquals(null, sending.send().html)

        sending.composer.edit("Hi ")
        sending.composer.format(3, 3, Kind.Bold)
        sending.composer.edit("Hi you")
        sending.composer.format(6, 6, Kind.Bold)
        sending.composer.edit("Hi you!")
        assertEquals("Hi <strong>you</strong>!", sending.send().html)

        sending.composer.edit("Hi")
        sending.composer.format(0, 2, Kind.Bold)
        sending.composer.edit("Hi you")
        assertEquals("Typing at the end of bold stays bold", "<strong>Hi you</strong>", sending.send().html)
    }

    // capability: composer.formatting
    @Test fun returnInAListStartsTheNextItemAndEndingItLeavesTheRestPlain() = runTest {
        val sending = Sending(this)
        sending.composer.state.first { !it.loading }
        sending.composer.edit("one")
        sending.composer.format(3, 3, Kind.Bullet)
        sending.composer.edit("one\n")
        sending.composer.edit("one\ntwo")
        sending.composer.edit("one\ntwo\n")
        sending.composer.format(8, 8, Kind.Bullet)
        sending.composer.edit("one\ntwo\nafter")
        assertEquals("<ul><li>one</li><li>two</li></ul>after", sending.send().html)
    }

    @Test fun returnOnAnEmptyItemOrBackspaceAtAnItemsStartLeavesTheBlock() {
        val list = listOf(ComposerStyle(0, 9, Kind.Bullet))
        fun left(old: String, new: String, caret: Int, styles: List<ComposerStyle> = list, typing: ComposerTyping? = null) =
            ComposerStyles.blockLeft(styles, typing, old, new, caret)
        assertEquals("An empty middle item", Kind.Bullet, left("one\n\ntwo", "one\n\n\ntwo", 4))
        assertEquals("An empty last item", Kind.Bullet, left("one\ntwo\n", "one\ntwo\n\n", 8))
        assertEquals("Return after an item's text starts the next", null, left("one\ntwo\n", "one\ntwo\n\n", 7))
        assertEquals("An empty first item chosen at the caret", Kind.Bullet,
            left("", "\n", 0, emptyList(), ComposerTyping(0, setOf(Kind.Bullet))))
        assertEquals("Backspace at an item's start", Kind.Bullet, left("one\ntwo", "onetwo", 4))
        assertEquals("Backspace in plain text", null, left("one\ntwo", "onetwo", 4, emptyList()))
    }

    // capability: composer.formatting
    @Test fun formattingSurvivesTheStoredDraftAndEditingASentMessage() = runTest {
        val room = ComposerRoom()
        val first = Sending(this, room)
        first.composer.state.first { !it.loading }
        first.composer.edit("Plan\nship it\nnow")
        first.composer.format(5, 12, Kind.Bullet)
        first.composer.format(5, 9, Kind.Bold)
        first.composer.close()

        val reopened = Sending(this, room)
        assertEquals("Plan\nship it\nnow", reopened.composer.state.first { !it.loading }.text)
        val html = "Plan<ul><li><strong>ship</strong> it</li></ul>now"
        assertEquals(html, reopened.send().html)

        reopened.composer.editMessage(ComposerTarget.Edit("\$one", "Plan\n- ship it\nnow", html))
        assertEquals("Plan\nship it\nnow", reopened.composer.state.value.text)
        assertEquals(html, reopened.send().html)
    }

    // capability: composer.formatting
    @Test fun aBlankLineAfterAListAndALinkOverMixedFormatsSurviveTheDraft() = runTest {
        val room = ComposerRoom()
        val first = Sending(this, room)
        first.composer.state.first { !it.loading }
        first.composer.edit("a\n\nsee docs here")
        first.composer.format(0, 1, Kind.Bullet)
        first.composer.format(7, 16, Kind.Link, "https://example.org")
        first.composer.format(7, 11, Kind.Bold)
        first.composer.close()

        val reopened = Sending(this, room)
        assertEquals("a\n\nsee docs here", reopened.composer.state.first { !it.loading }.text)
        val message = reopened.send()
        assertEquals("<ul><li>a</li></ul><br>see <a href=\"https://example.org\"><strong>docs</strong> here</a>", message.html)
        assertEquals("- a\n\nsee docs here (https://example.org)", message.body)
    }

    @Test fun editingAMessageFromAnotherAppKeepsUnderlineAndIgnoresItsHtmlLayout() = runTest {
        val sending = Sending(this)
        sending.composer.state.first { !it.loading }
        sending.composer.editMessage(ComposerTarget.Edit("\$one", "under\nline", "<p><u>under</u></p>\n<p>line</p>\n"))
        assertEquals("under\nline", sending.composer.state.value.text)
        assertEquals("<u>under</u><br>line", sending.send().html)
    }

    private data class Case(val name: String, val text: String, val start: Int, val kind: Kind, val href: String? = null)
}
