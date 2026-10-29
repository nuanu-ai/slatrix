package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MentionCandidate
import ai.nuanu.slatrix.core.MentionPeople
import ai.nuanu.slatrix.core.MentionPerson
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ComposerActions
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class MessageComposerTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
    private val mira = MentionPerson("@mira:example.org", "Mira Chen")
    private val text = mutableStateOf("")
    private val mentions = mutableListOf<Triple<Int, Int, MentionCandidate>>()
    private var peopleAsked = false

    private fun show() {
        val said = ConversationMessage("a", "\$a", "@sam:example.org", "Sam", "Morning", null, 1_700_000_000_000L,
            MessageKind.Text, MessageSendState.Sent, false, "S", 0)
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(said), loading = false, hasMore = false),
                    ComposerState(text.value, loading = false), { text.value = it }, {}, {}, {}, {}, {}, {}, {},
                    composerActions = ComposerActions(people = MentionPeople(listOf(mira, MentionPerson("@sam:example.org", "Sam Okafor")), true),
                        onNeedPeople = { peopleAsked = true },
                        onMention = { start, end, candidate -> mentions += Triple(start, end, candidate) }))
            }
        }
    }

    // capability: composer.mentions
    @Test fun typingAtSuggestsPeopleAndChoosingOneMentionsThem() {
        show()
        compose.onNodeWithContentDescription("Message #design").performTextInput("Hi @mi")
        compose.runOnIdle { assertTrue(peopleAsked) }
        compose.onNodeWithText("Mira Chen").performClick()
        compose.runOnIdle { assertEquals(listOf(Triple(3, 6, MentionCandidate.Member(mira))), mentions) }
    }

    @Test fun theAtButtonStartsAMentionWhereYouType() {
        show()
        compose.onNodeWithContentDescription("Message #design").performTextInput("Hi")
        compose.onNodeWithContentDescription("Mention someone").performClick()
        compose.runOnIdle { assertEquals("Hi @", text.value) }
        compose.onNodeWithText("Sam Okafor").assertExists()
    }

    // capability: composer.attachments
    @Test fun plusPicksFilesAndHandsThemOver() {
        val picked = listOf(android.net.Uri.parse("content://media/picker/1"), android.net.Uri.parse("content://media/picker/2"))
        val attached = mutableListOf<android.net.Uri>()
        val registry = object : androidx.activity.result.ActivityResultRegistry() {
            override fun <I, O> onLaunch(requestCode: Int, contract: androidx.activity.result.contract.ActivityResultContract<I, O>,
                input: I, options: androidx.core.app.ActivityOptionsCompat?) {
                dispatchResult(requestCode, android.app.Activity.RESULT_OK, android.content.Intent().apply {
                    clipData = android.content.ClipData.newRawUri(null, picked[0]).apply { addItem(android.content.ClipData.Item(picked[1])) }
                })
            }
        }
        compose.setContent {
            androidx.compose.runtime.CompositionLocalProvider(androidx.activity.compose.LocalActivityResultRegistryOwner provides
                object : androidx.activity.result.ActivityResultRegistryOwner { override val activityResultRegistry = registry }) {
                SlatrixTheme {
                    LiveChannelScreen(room, ConversationState(emptyList(), loading = false, hasMore = false),
                        ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {},
                        composerActions = ComposerActions(onAttach = { attached += it }))
                }
            }
        }
        compose.onNodeWithContentDescription("Attachments").performClick()
        compose.onNodeWithText("Files").performClick()
        compose.runOnIdle { assertEquals(picked, attached) }
    }

    @Test fun anUploadShowsItsProgressOnTheMessage() {
        val photo = ConversationMessage("p", null, "@me:example.org", "Me", "photo.png", null, 1_700_000_000_000L,
            MessageKind.Attachment, MessageSendState.Sending, true, "M", 0, uploadProgress = 0.25f)
        compose.setContent {
            SlatrixTheme {
                LiveChannelScreen(room, ConversationState(listOf(photo), loading = false, hasMore = false),
                    ComposerState(loading = false), {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNode(androidx.compose.ui.test.hasProgressBarRangeInfo(androidx.compose.ui.semantics.ProgressBarRangeInfo(0.25f, 0f..1f)))
            .assertExists()
    }

    @Test fun theEmojiButtonInsertsAnEmojiWhereYouType() {
        show()
        compose.onNodeWithContentDescription("Message #design").performTextInput("Ship it")
        compose.onNodeWithContentDescription("Emoji").performClick()
        compose.onNodeWithContentDescription("Search emoji").performTextInput("rocket")
        compose.waitUntil { compose.onAllNodes(hasContentDescription("rocket")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("rocket").performClick()
        compose.runOnIdle { assertEquals("Ship it🚀", text.value) }
    }
}
