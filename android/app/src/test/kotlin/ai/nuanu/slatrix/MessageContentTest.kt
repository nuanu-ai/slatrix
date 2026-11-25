package ai.nuanu.slatrix

import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import ai.nuanu.slatrix.ui.account.PILL_ANNOTATION_TAG
import ai.nuanu.slatrix.ui.account.PillKind
import ai.nuanu.slatrix.ui.account.TextPill
import ai.nuanu.slatrix.ui.account.computePillRects
import ai.nuanu.slatrix.ui.account.dayLabel
import android.graphics.Canvas
import android.view.View
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.text.TextLayoutResult
import kotlin.math.abs
import org.robolectric.Shadows.shadowOf
import java.io.File
import androidx.test.core.app.ApplicationProvider
import android.net.Uri
import android.content.Intent
import androidx.core.content.FileProvider
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageReaction
import ai.nuanu.slatrix.core.MessageThread
import ai.nuanu.slatrix.core.ReplyPreview
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.MessageActions
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CompletableDeferred
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** What a conversation row shows of a message. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class MessageContentTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)

    private var toggled: Pair<ConversationMessage, String>? = null
    private var thread: String? = null
    private var jumped: String? = null
    private var opened: MessageAttachment? = null
    private val picture = CompletableDeferred<ByteArray?>()
    /** The widths pictures were asked for, in pixels. */
    private val asked = mutableListOf<Int>()
    private val opening = CompletableDeferred<String?>()
    private var download: File? = null

    private fun show(vararg messages: ConversationMessage, set: (@Composable () -> Unit) -> Unit = { compose.setContent(it) }) {
        set {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(messages.toList(), loading = false, hasMore = false, ownUserId = "@me:example.org",
                    names = mapOf("@mira:example.org" to "Mira")),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                    onOpenThread = { thread = it }, actions = MessageActions(onReact = { message, key -> toggled = message to key }),
                    onOpenMessage = { jumped = it }, loadPicture = { _, width, _, _ -> asked += width; picture.await() },
                    onOpenFile = { opened = it; opening.await() }, loadFile = { download },
                    onOpenReplies = { root, _ -> thread = root })
            }
        }
    }

    private val source = TestMediaSource("mxc://example.org/office")

    private fun SemanticsNodeInteraction.text(): AnnotatedString =
        fetchSemanticsNode().config[SemanticsProperties.Text].single()

    // capability: message.rich-text
    @Test fun formattedTextShowsItsStylesNotItsMarkup() {
        show(message("**Ship** it", html = "<strong>Ship</strong> it"))
        val text = compose.onNodeWithText("Ship it", useUnmergedTree = true).text()
        assertEquals(listOf("Ship"), text.spanStyles.filter { it.item.fontWeight == FontWeight.Bold }.map { text.substring(it.start, it.end) })
    }

    // capability: message.rich-text
    @Test fun aListItemsTextAfterANestedListLinesUpWithTheItem() {
        show(message("one inner tail", html = "<ul><li>one<ul><li>inner</li></ul>tail</li></ul><blockquote>said<ul><li>this</li></ul></blockquote>"))
        fun left(text: String) = compose.onNodeWithText(text, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.left
        assertEquals(left("one"), left("tail"))
        assertTrue("The nested item sits further in", left("inner") > left("one"))
        assertTrue("A list in a quote sits past the quote's bar", left("this") > left("one"))
    }

    @Test fun aBlankLineBetweenParagraphsLeavesLessThanALineOfSpace() {
        show(message("Lines one\nLines two"), message("Paragraph one\n\nParagraph two"))
        fun span(first: String, second: String): Float {
            fun bounds(text: String) = compose.onNodeWithText(text, substring = true, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
            return bounds(second).bottom - bounds(first).top
        }
        val lines = span("Lines one", "Lines two")
        val gap = span("Paragraph one", "Paragraph two") - lines
        assertTrue("A blank line took $gap px against a line of ${lines / 2} px", gap > 0 && gap < lines / 4)
    }

    // capability: message.edited
    @Test fun anEditedMessageEndsWithSlacksEditedMark() {
        show(message("Fixed the typo").copy(edited = true))
        compose.onNodeWithText("Fixed the typo (edited)", useUnmergedTree = true).assertExists()
    }

    // capability: message.mention-pills
    @Test fun aMentionOfYouStandsOutFromOtherMentions() {
        show(message("@me @sam", html = "<a href=\"https://matrix.to/#/@me:example.org\">Me</a> " +
            "<a href=\"https://matrix.to/#/@sam:example.org\">Sam</a>"))
        val text = compose.onNodeWithText("@Me", substring = true, useUnmergedTree = true).text()
        assertTrue("Mentions draw rounded pills instead of flat background spans",
            text.spanStyles.none { it.item.background != Color.Unspecified })
        val pills = text.getStringAnnotations("slatrix.pill", 0, text.length).sortedBy { it.start }
        assertEquals(listOf("mention_you" to "@Me", "mention" to "@Sam"),
            pills.map { it.item to text.substring(it.start, it.end).trim('\u202F', '\u2009', '\u2006') })
    }

    // capability: message.mention-pills
    @Test fun aMentionNeverBreaksAcrossLinesAndMentionsSideBySideStayApart() {
        show(message("three", html = "<a href=\"https://matrix.to/#/@sam:example.org\">Sam Okafor</a>" +
            "<a href=\"https://matrix.to/#/@wanda:example.org\">wanda-moss</a><a href=\"https://matrix.to/#/@lee:example.org\">Lee</a> hi"))
        val text = compose.onNodeWithText("Okafor", substring = true, useUnmergedTree = true).text()
        assertTrue("Mentions use rounded pill ranges, not flat SpanStyle backgrounds",
            text.spanStyles.none { it.item.background != Color.Unspecified })
        val pills = text.getStringAnnotations("slatrix.pill", 0, text.length).sortedBy { it.start }
        assertEquals(3, pills.size)
        for (pill in pills) {
            val name = text.substring(pill.start, pill.end)
            assertFalse("\"$name\" can break at a space or hyphen", name.any { it == ' ' || it == '-' })
        }
        pills.zipWithNext { first, next -> assertTrue("Two mentions touch", first.end < next.start) }
    }

    // capability: message.rich-text
    @Test fun inlineCodeAndMentionsRenderRoundedPillsAcrossWrappedLinesAndOutgoingBubbles() {
        val longCode = "very-long-inline-command-name-that-wraps-cleanly-across-multiple-visual-lines-in-a-bubble"
        val incoming = message("code", html = "Check <code>b7f6a3f</code>, <code>sshd</code>, and <code>$longCode</code>.")
        val outgoing = message("own", html = "<a href=\"https://matrix.to/#/@sam:example.org\">alex-salomatov</a> check <code>revit-work</code>")
            .copy(own = true, senderId = "@me:example.org", senderName = "Me")
        val codeBlock = message("block", html = "<pre><code>./gradlew test</code></pre>")
        show(incoming, outgoing, codeBlock)

        val incomingText = compose.onNodeWithText("b7f6a3f", substring = true, useUnmergedTree = true).text()
        assertTrue("Inline code uses rounded pill ranges, not flat SpanStyle backgrounds",
            incomingText.spanStyles.none { it.item.background != Color.Unspecified })
        val codePills = incomingText.getStringAnnotations("slatrix.pill", 0, incomingText.length).sortedBy { it.start }
        assertEquals(listOf("code" to "b7f6a3f", "code" to "sshd", "code" to longCode),
            codePills.map { it.item to incomingText.substring(it.start, it.end).trim('\u202F', '\u2009', '\u2006') })

        val outgoingText = compose.onNodeWithText("revit-work", substring = true, useUnmergedTree = true).text()
        assertTrue("Outgoing pills omit flat SpanStyle backgrounds",
            outgoingText.spanStyles.none { it.item.background != Color.Unspecified })
        val outPills = outgoingText.getStringAnnotations("slatrix.pill", 0, outgoingText.length).sortedBy { it.start }
        assertEquals(listOf("mention" to "@alex\u2011salomatov", "code" to "revit-work"),
            outPills.map { it.item to outgoingText.substring(it.start, it.end).trim('\u202F', '\u2009', '\u2006') })

        val blockText = compose.onNodeWithText("./gradlew test", useUnmergedTree = true).text()
        assertTrue("Code blocks do not emit inline code pills",
            blockText.getStringAnnotations(PILL_ANNOTATION_TAG, 0, blockText.length).isEmpty())

        // Verify wrapped multi-line inline code computes multiple non-overlapping pill rectangles within layout width.
        val layouts = mutableListOf<TextLayoutResult>()
        compose.onNodeWithText("b7f6a3f", substring = true, useUnmergedTree = true)
            .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        val layout = layouts.single()
        val longAnnotation = codePills.last()
        val rects = computePillRects(
            layout,
            listOf(TextPill(longAnnotation.start, longAnnotation.end, PillKind.Code, Color.Gray)),
            wrapPadPx = 4f,
        )
        assertTrue("Wrapped inline code spans multiple pill segments (got ${rects.size})", rects.size >= 2)
        for (rect in rects) {
            assertTrue("Pill left >= 0 (${rect.left})", rect.left >= 0f)
            assertTrue("Pill right <= width (${rect.right} <= ${layout.size.width})", rect.right <= layout.size.width.toFloat())
            assertTrue("Pill has positive area", rect.right > rect.left && rect.bottom > rect.top)
        }
        rects.zipWithNext { upper, lower ->
            assertTrue("Wrapped pill lines keep vertical separation (${upper.bottom} < ${lower.top})", upper.bottom < lower.top)
        }
        // Verify thin padding char inside pills renders with positive width smaller than a normal space.
        val padBox = layout.getBoundingBox(codePills.first().start)
        val spaceIndex = incomingText.indexOf(' ')
        val spaceBox = layout.getBoundingBox(spaceIndex)
        assertTrue("Pill pad width (${padBox.width}) > 0", padBox.width > 0f)
        assertTrue("Pill pad width (${padBox.width}) <= regular space (${spaceBox.width})", padBox.width <= spaceBox.width + 0.5f)
    }

    // capability: message.mention-pills
    @Test fun roundedPillFillsPaintInsideIncomingAndOutgoingBubbles() {
        lateinit var view: View
        val incoming = message("me", html = "<a href=\"https://matrix.to/#/@me:example.org\">Me</a> check <code>sshd</code>")
        val outgoing = message("out", html = "<a href=\"https://matrix.to/#/@sam:example.org\">Sam</a> check <code>revit-work</code>")
            .copy(own = true, senderId = "@me:example.org", senderName = "Me")
        compose.setContent {
            view = LocalView.current
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(incoming, outgoing), loading = false, hasMore = false, ownUserId = "@me:example.org"),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.waitForIdle()
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
        val tokens = DesignTokens.colors(false)
        val bubbleIn = tokens.getValue("bubbleIn")
        val accentFill = tokens.getValue("accentFill")
        val mentionYouComposite = tokens.getValue("mentionYouFill").compositeOver(bubbleIn)
        val inCodeComposite = tokens.getValue("textBody").copy(alpha = 0.08f).compositeOver(bubbleIn)
        val outMentionComposite = Color.Black.copy(alpha = 0.18f).compositeOver(accentFill)
        val outCodeComposite = Color.Black.copy(alpha = 0.16f).compositeOver(accentFill)

        fun matches(a: Color, b: Color) =
            abs(a.red - b.red) < 0.04f && abs(a.green - b.green) < 0.04f && abs(a.blue - b.blue) < 0.04f

        fun assertRoundedPill(query: String, kindTag: String, expectedFill: Color, expectedBackdrop: Color) {
            val node = compose.onNodeWithText(query, substring = true, useUnmergedTree = true)
            val bounds = node.fetchSemanticsNode().boundsInRoot
            val layouts = mutableListOf<TextLayoutResult>()
            node.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
            val text = node.text()
            val annotation = text.getStringAnnotations(PILL_ANNOTATION_TAG, 0, text.length).first { it.item == kindTag }
            val rect = computePillRects(layouts.single(), listOf(TextPill(annotation.start, annotation.end, PillKind.Mention, expectedFill)), 0f).single()
            var painted = 0
            val leftPx = (bounds.left + rect.left).toInt().coerceIn(0, bitmap.width - 1)
            val rightPx = (bounds.left + rect.right).toInt().coerceIn(0, bitmap.width - 1)
            val topPx = (bounds.top + rect.top).toInt().coerceIn(0, bitmap.height - 1)
            val bottomPx = (bounds.top + rect.bottom).toInt().coerceIn(0, bitmap.height - 1)
            for (y in topPx..bottomPx) {
                for (x in leftPx..rightPx) {
                    if (matches(Color(bitmap.getPixel(x, y)), expectedFill)) painted++
                }
            }
            assertTrue("Expected painted rounded pill pixels for $query/$kindTag (found $painted)", painted > 20)
            val corner = Color(bitmap.getPixel(leftPx, topPx))
            assertTrue("Corner pixel of $query/$kindTag should stay backdrop $expectedBackdrop (got $corner)",
                matches(corner, expectedBackdrop))
        }

        assertRoundedPill("@Me", "mention_you", mentionYouComposite, bubbleIn)
        assertRoundedPill("sshd", "code", inCodeComposite, bubbleIn)
        assertRoundedPill("@Sam", "mention", outMentionComposite, accentFill)
        assertRoundedPill("revit-work", "code", outCodeComposite, accentFill)
    }

    // capability: message.reactions.show
    // capability: message.reactions.toggle
    @Test fun reactionsShowAsChipsWithYoursSelectedAndATapTogglesOne() {
        val shipped = message("Ship it").copy(reactions = listOf(
            MessageReaction("👍", 2, true, listOf("@mira:example.org", "@me:example.org")),
            MessageReaction("🎉", 1, false, listOf("@sam:example.org")),
        ))
        show(shipped)
        compose.onNode(hasText("👍") and hasContentDescription("👍 2, You and Mira")).assertIsSelected()
        compose.onNode(hasText("🎉") and hasContentDescription("🎉 1, sam")).assertIsNotSelected().performClick()
        compose.runOnIdle { assertEquals(shipped to "🎉", toggled) }
    }

    // capability: message.reactions.show
    @Test fun everyPillShowsItsEmojiAndCountHoweverFewReacted() {
        show(message("Ship it").copy(reactions = listOf(
            MessageReaction("👍", 2, true, listOf("@mira:example.org", "@me:example.org")),
            MessageReaction("🎉", 4, false, listOf("@a:example.org", "@b:example.org", "@c:example.org", "@d:example.org")),
        )))
        compose.onNode(hasText("👍") and hasText("2")).assertIsDisplayed()
        compose.onNode(hasText("🎉") and hasText("4")).assertIsDisplayed()
    }

    // capability: message.reactions.show
    @Test fun aChipDescribesItsEmojiCountAndAtMostThreeWhoReacted() {
        val senders = listOf("@me:example.org") + (1..99).map { "@p$it:example.org" }
        show(message("Ship it").copy(reactions = listOf(MessageReaction("🎉", 100, true, senders))))
        compose.onNode(hasText("🎉") and hasContentDescription("🎉 100, You, p1, p2 and 97 others")).assertIsSelected()
    }

    // capability: message.reactions.show
    @Test fun longPressingAReactionShowsWhoReacted() {
        show(message("Ship it").copy(reactions = listOf(
            MessageReaction("👍", 3, true, listOf("@mira:example.org", "@me:example.org", "@sam:example.org")),
        )))
        compose.onNode(hasText("👍")).performTouchInput { longClick() }
        compose.onNodeWithText("Mira, You and sam", substring = true).assertIsDisplayed()
    }

    // capability: message.thread-summary
    @Test fun aThreadRootShowsItsRepliesAndOpensTheThread() {
        show(message("Plan?").copy(thread = MessageThread(3, "Sam Okafor", System.currentTimeMillis() - 2 * 3_600_000L)))
        compose.onNodeWithText("3 replies", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Last reply 2 hours ago", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("3 replies", useUnmergedTree = true).performClick()
        compose.runOnIdle { assertEquals("\$Plan?", thread) }
    }

    // capability: message.reply-preview
    @Test fun aReplyQuotesItsParentAndATapOpensTheParentWhereItIs() {
        show(message("Agreed").copy(replyTo = ReplyPreview("\$parent", ReplyPreview.State.Ready, "Sam", "Parent summary")))
        compose.onNodeWithText("Sam", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Parent summary", useUnmergedTree = true).performClick()
        compose.runOnIdle { assertEquals("\$parent", jumped) }
    }

    // capability: message.reply-preview
    @Test fun aReplyKeepsItsHeightWhenItsParentLoads() {
        val reply = mutableStateOf(message("Agreed").copy(replyTo = ReplyPreview("\$p", ReplyPreview.State.Loading)))
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(reply.value), loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        fun top() = compose.onNodeWithText("Agreed", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.top
        val loading = top()
        compose.runOnIdle { reply.value = reply.value.copy(replyTo = ReplyPreview("\$p", ReplyPreview.State.Ready, "Sam", "Ship it?")) }
        compose.onNodeWithText("Ship it?", useUnmergedTree = true).assertExists()
        assertEquals(loading, top())
    }

    // capability: message.image
    @Test fun anImageTakesItsBoxBeforeItLoadsAndKeepsItAfter() {
        show(message("office.jpg").copy(kind = MessageKind.Attachment,
            attachment = MessageAttachment(MessageAttachment.Kind.Image, "office.jpg", "image/jpeg", 2_000_000, 1600, 900, source)))
        val before = compose.onNodeWithContentDescription("office.jpg").fetchSemanticsNode().boundsInRoot
        assertEquals("The box keeps the image's shape", 900f / 1600f, before.height / before.width, 0.01f)
        val png = ByteArrayOutputStream().also { Bitmap.createBitmap(16, 9, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, it) }
        picture.complete(png.toByteArray())
        compose.waitForIdle()
        assertEquals(before, compose.onNodeWithContentDescription("office.jpg").fetchSemanticsNode().boundsInRoot)
        compose.onNodeWithText("office.jpg", useUnmergedTree = true).assertDoesNotExist()
    }

    // capability: message.image
    @Test fun anImageIsDecodedAgainForItsNewBoxWhenTheRoomForItChanges() {
        val resized = TestMediaSource("mxc://example.org/resized")
        val width = mutableStateOf(412.dp)
        show(message("wide.png").copy(kind = MessageKind.Attachment,
            attachment = MessageAttachment(MessageAttachment.Kind.Image, "wide.png", "image/png", 2_000_000, 1600, 900, resized)),
            set = { content -> compose.setContent { Box(Modifier.width(width.value)) { content() } } })
        val png = ByteArrayOutputStream().also { Bitmap.createBitmap(16, 9, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, it) }
        picture.complete(png.toByteArray())
        compose.waitUntil { asked.isNotEmpty() }
        val first = asked.last()

        width.value = 320.dp
        compose.waitUntil { asked.last() < first }
    }

    // capability: message.image
    @Test fun anImageWithoutACaptionCarriesItsTimeOnItsCorner() {
        show(message("office.jpg").copy(kind = MessageKind.Attachment,
            attachment = MessageAttachment(MessageAttachment.Kind.Image, "office.jpg", "image/jpeg", 2_000_000, 1600, 900, source)))
        val image = compose.onNodeWithContentDescription("office.jpg").fetchSemanticsNode().boundsInRoot
        val time = compose.onNode(hasText("AM", substring = true) or hasText("PM", substring = true), useUnmergedTree = true)
            .fetchSemanticsNode().boundsInRoot
        assertTrue("The time $time sits on the image $image, as in a messenger", image.contains(time.topLeft) && image.contains(time.bottomRight))
    }

    // capability: message.media-viewer
    @Test fun tappingAnImageOpensItFullScreenUntilClosed() {
        show(message("office.jpg").copy(kind = MessageKind.Attachment,
            attachment = MessageAttachment(MessageAttachment.Kind.Image, "office.jpg", "image/jpeg", 2_000_000, 1600, 900, source)))
        compose.onNodeWithContentDescription("office.jpg").performClick()
        compose.onNodeWithContentDescription("Close").assertIsDisplayed().performClick()
        compose.onNodeWithContentDescription("Close").assertDoesNotExist()
    }

    // capability: message.media-viewer
    @Test fun theViewerSaysWhoSentThePictureAndSharesOrSavesIt() {
        val context = ApplicationProvider.getApplicationContext<Application>()
        download = File(context.cacheDir, "media/office.jpg").apply { parentFile!!.mkdirs(); writeText("pixels") }
        show(message("office.jpg").copy(kind = MessageKind.Attachment,
            attachment = MessageAttachment(MessageAttachment.Kind.Image, "office.jpg", "image/jpeg", 6, 1600, 900, source)))
        compose.onNodeWithContentDescription("office.jpg").performClick()
        compose.onNode(hasText("Mira") and hasAnyAncestor(isDialog())).assertIsDisplayed()
        compose.onNode(hasText(dayLabel(1_700_000_000_000L), substring = true) and hasAnyAncestor(isDialog())).assertIsDisplayed()

        // FileProvider keeps each authority's folders for the process, and each Robolectric test gets its own cache folder.
        val cache = FileProvider::class.java.getDeclaredField("sCache").apply { isAccessible = true }.get(null) as MutableMap<*, *>
        cache.clear()
        try {
            compose.onNodeWithContentDescription("Share").performClick()
            compose.waitUntil { shadowOf(context).peekNextStartedActivity() != null }
            val shared = shadowOf(context).nextStartedActivity.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)!!
            assertEquals(Intent.ACTION_SEND, shared.action)
            assertEquals("image/jpeg", shared.type)
            val uri = shared.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)!!
            assertEquals("pixels", context.contentResolver.openInputStream(uri)!!.reader().readText())
        } finally {
            cache.clear()
        }

        compose.onNodeWithContentDescription("Save to device").performClick()
        // Held, since the notice leaves on its own after a moment.
        compose.mainClock.autoAdvance = false
        compose.waitUntil {
            compose.mainClock.advanceTimeByFrame()
            compose.onAllNodesWithText("Saved to Pictures").fetchSemanticsNodes().isNotEmpty()
        }
    }

    // capability: message.media-viewer
    @Test fun theViewerStaysOnTheSameImageAndZoomWhenThePhoneTurns() {
        val restoration = StateRestorationTester(compose)
        val turned = TestMediaSource("mxc://example.org/turned")
        show(message("office.jpg").copy(kind = MessageKind.Attachment,
            attachment = MessageAttachment(MessageAttachment.Kind.Image, "office.jpg", "image/jpeg", 2_000_000, 1600, 900, turned)),
            set = { restoration.setContent(it) })
        val png = ByteArrayOutputStream().also { Bitmap.createBitmap(16, 9, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, it) }
        picture.complete(png.toByteArray())
        compose.onNodeWithContentDescription("office.jpg").performClick()
        val viewer = hasContentDescription("office.jpg") and hasAnyAncestor(isDialog())
        compose.waitUntil { compose.onAllNodes(viewer).fetchSemanticsNodes().isNotEmpty() }
        val fitted = compose.onNode(viewer).fetchSemanticsNode().boundsInRoot
        compose.onNode(viewer).performTouchInput { doubleClick() }
        compose.waitForIdle()
        val zoomed = compose.onNode(viewer).fetchSemanticsNode().boundsInRoot
        assertTrue("Double-tap zooms in", zoomed.width > fitted.width)

        restoration.emulateSavedInstanceStateRestore()
        compose.waitUntil { compose.onAllNodes(viewer).fetchSemanticsNodes().isNotEmpty() }
        assertEquals(zoomed, compose.onNode(viewer).fetchSemanticsNode().boundsInRoot)
    }

    // capability: message.file
    @Test fun aFileShowsAsSlacksFileRowAndATapOpensIt() {
        val report = MessageAttachment(MessageAttachment.Kind.File, "Q3 report.pdf", "application/pdf", 250_000, null, null, source)
        show(message("Q3 report.pdf").copy(kind = MessageKind.Attachment, attachment = report))
        compose.onNodeWithText("PDF", substring = true, useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Q3 report.pdf", useUnmergedTree = true).performClick()
        compose.runOnIdle { assertEquals(report, opened) }
    }

    // capability: message.file
    @Test fun aFileKeepsOpeningAfterItsRowScrollsAwayAndSaysWhenItCannot() {
        val report = MessageAttachment(MessageAttachment.Kind.File, "Q3 report.pdf", "application/pdf", 250_000, null, null, source)
        show(message("Q3 report.pdf").copy(kind = MessageKind.Attachment, attachment = report), *(1..40).map { message("Message $it") }.toTypedArray())
        repeat(10) { compose.onNode(hasScrollAction()).performTouchInput { swipeDown() } }
        compose.onNodeWithText("Q3 report.pdf", useUnmergedTree = true).performClick()
        repeat(10) { compose.onNode(hasScrollAction()).performTouchInput { swipeUp() } }
        compose.onNodeWithText("Q3 report.pdf", useUnmergedTree = true).assertDoesNotExist()
        opening.complete("Couldn’t download Q3 report.pdf.")
        compose.onNodeWithText("Couldn’t download Q3 report.pdf.").assertIsDisplayed()
    }

    @Test fun groupedNewSenderAndPostAttachmentBubblesKeepDistinctVerticalRhythm() {
        val report = MessageAttachment(MessageAttachment.Kind.File, "Q3 report.pdf", "application/pdf", 250_000, null, null, source)
        val first = message("First line")
        val groupedText = message("Second line").copy(grouped = true)
        val file = message("Q3 report.pdf").copy(kind = MessageKind.Attachment, attachment = report, grouped = true)
        val afterFile = message("Following file").copy(grouped = true)
        val otherSender = ConversationMessage("other", "\$other", "@sam:example.org", "Sam", "New speaker", null,
            1_700_000_060_000L, MessageKind.Text, MessageSendState.Sent, false, "S", 1, grouped = false)
        show(first, groupedText, file, afterFile, otherSender)
        val density = compose.density.density
        // Each bubble's first text line sits BubbleInsetVertical (6dp) below its top edge; the merged row starts above top padding.
        fun textTop(text: String) = compose.onNodeWithText(text, useUnmergedTree = true).fetchSemanticsNode().boundsInRoot.top
        fun rowTop(text: String) = compose.onNodeWithText(text).fetchSemanticsNode().boundsInRoot.top
        val bubbleInset = 6f * density
        val groupedGap = textTop("Second line") - rowTop("Second line") - bubbleInset
        val afterFileGap = textTop("Following file") - rowTop("Following file") - bubbleInset
        val newSenderGap = textTop("Sam") - rowTop("New speaker") - bubbleInset
        assertEquals("Grouped bubbles sit 3dp apart", 3f * density, groupedGap, 1.5f)
        assertEquals("Grouped bubble after a file sits 6dp below it", 6f * density, afterFileGap, 1.5f)
        assertEquals("New sender sits 12dp below the previous bubble", 12f * density, newSenderGap, 1.5f)
    }

    // capability: message.deleted
    @Test fun aDeletedMessageReadsAsSlacksInItalics() {
        show(message("This message was deleted").copy(kind = MessageKind.Deleted))
        val text = compose.onNodeWithText("This message was deleted.", useUnmergedTree = true).text()
        assertEquals(FontStyle.Italic, text.spanStyles.single().item.fontStyle)
    }

    private fun message(body: String, html: String? = null) = ConversationMessage(body, "\$$body", "@mira:example.org", "Mira", body,
        html, 1_700_000_000_000L, MessageKind.Text, MessageSendState.Sent, false, "M", 0)
}
