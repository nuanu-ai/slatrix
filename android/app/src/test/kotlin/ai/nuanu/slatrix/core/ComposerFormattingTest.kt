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
        val s = Sending(this)
        s.composer.state.first { !it.loading }
        for ((name, text, kind, href) in listOf(
            Quad("Bold", "Hi there", Kind.Bold, null),
            Quad("Italic", "soft", Kind.Italic, null),
            Quad("Strikethrough", "gone", Kind.Strike, null),
            Quad("A link, with its address after the text in the body", "docs", Kind.Link, "https://example.org/a?b=1&c"),
            Quad("A bulleted list", "one\ntwo", Kind.Bullet, null),
            Quad("A numbered list", "one\ntwo", Kind.Numbered, null),
            Quad("A quote, line by line", "said\nthis", Kind.Quote, null),
            Quad("A code block, fenced in the body", "if a < b {\n  go()", Kind.CodeBlock, null),
        )) {
            s.composer.edit(text)
            val start = if (name == "Bold") 3 else 0
            s.composer.format(start, text.length, kind, href)
            assertEquals(name, expected(name), s.send())
        }
        s.composer.edit("a < b")
        s.composer.format(0, 5, Kind.Code)
        assertEquals(expected("Inline code, with its body in backticks"), s.send())
    }

    // capability: composer.formatting
    @Test fun boldGoesOnASelectionAndOffAgainAndAtTheCaretAppliesToWhatIsTypedNext() = runTest {
        val s = Sending(this)
        s.composer.state.first { !it.loading }
        s.composer.edit("Hi there")
        s.composer.format(3, 8, Kind.Bold)
        s.composer.format(3, 8, Kind.Bold)
        assertEquals(null, s.send().html)

        s.composer.edit("Hi ")
        s.composer.format(3, 3, Kind.Bold)
        s.composer.edit("Hi you")
        s.composer.format(6, 6, Kind.Bold)
        s.composer.edit("Hi you!")
        assertEquals("Hi <strong>you</strong>!", s.send().html)

        s.composer.edit("Hi")
        s.composer.format(0, 2, Kind.Bold)
        s.composer.edit("Hi you")
        assertEquals("Typing at the end of bold stays bold", "<strong>Hi you</strong>", s.send().html)
    }

    // capability: composer.formatting
    @Test fun returnInAListStartsTheNextItemAndOnAnEmptyItemEndsTheList() = runTest {
        val s = Sending(this)
        s.composer.state.first { !it.loading }
        s.composer.edit("one")
        s.composer.format(3, 3, Kind.Bullet)
        s.composer.edit("one\n")
        s.composer.edit("one\ntwo")
        s.composer.edit("one\ntwo\n")
        s.composer.edit("one\ntwo\n\n")
        assertEquals("one\ntwo\n", s.composer.state.value.text)
        s.composer.edit("one\ntwo\nafter")
        assertEquals("<ul><li>one</li><li>two</li></ul>after", s.send().html)
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

    private data class Quad(val name: String, val text: String, val kind: Kind, val href: String?)
}
