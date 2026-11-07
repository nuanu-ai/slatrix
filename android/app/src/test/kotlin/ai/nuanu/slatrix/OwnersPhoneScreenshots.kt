package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ActivityItem
import ai.nuanu.slatrix.core.ActivityKind
import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ComposerStyle
import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationRow
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.DayDivider
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageReaction
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.MessageThread
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ActivityScreen
import ai.nuanu.slatrix.ui.account.ComposerActions
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.account.LiveHomeScreen
import ai.nuanu.slatrix.ui.account.MessageActions
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Density
import com.github.takahirom.roborazzi.captureScreenRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.ParameterizedRobolectricTestRunner.Parameters
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.time.LocalDate
import java.time.ZoneId

/**
 * A direct message, a channel, composing, a long press and Activity on the owner's phone, 320 dp wide with the font at
 * 1.15, at twice the pixels so each lies beside its design board as drawn.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "en-rGB-w320dp-h704dp-xhdpi")
class OwnersPhoneScreenshots(private val screen: String, private val dark: Boolean) {
    @get:Rule val compose = createComposeRule()

    @Test fun render() {
        compose.setContent {
            CompositionLocalProvider(LocalDensity provides Density(LocalDensity.current.density, 1.15f)) {
                SlatrixTheme(dark = dark) { Screen() }
            }
        }
        when (screen) {
            "Menu" -> {
                compose.onNode(hasScrollAction()).performScrollToNode(hasText("поняла", substring = true))
                compose.onNodeWithText("поняла", substring = true).performTouchInput { longClick() }
            }
            "Compose" -> compose.onNodeWithContentDescription("Formatting").performClick()
            "Activity" -> compose.onAllNodesWithText("Activity").onLast().performClick()
        }
        compose.waitForIdle()
        captureScreenRoboImage("build/outputs/roborazzi/OwnersPhone-$screen-${if (dark) "dark" else "light"}.png")
    }

    @androidx.compose.runtime.Composable
    private fun Screen() {
        fun at(daysAgo: Long, hour: Int, minute: Int) = LocalDate.now().minusDays(daysAgo).atTime(hour, minute)
            .atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val me = "@du:example.org"
        val people = mapOf(me to "Dmitry Ukhanov", "@anna:example.org" to "Анна Белова", "@igor:example.org" to "Игорь Соколов",
            "@deploy:example.org" to "deploy agent")
        var count = 0
        fun day(daysAgo: Long) = DayDivider("day$daysAgo", at(daysAgo, 0, 0))
        fun say(who: String, daysAgo: Long, hour: Int, minute: Int, body: String, grouped: Boolean = false,
            reactions: List<MessageReaction> = emptyList()): ConversationMessage {
            val name = people.getValue(who)
            count++
            return ConversationMessage("m$count", "\$m$count", who, name, body, null, at(daysAgo, hour, minute), MessageKind.Text,
                MessageSendState.Sent, who == me, AvatarPlaceholder.initials(name), AvatarPlaceholder.colorIndex(name), grouped,
                reactions = reactions)
        }
        val anna = "@anna:example.org"
        val dm = listOf<ConversationRow>(
            day(10),
            say(anna, 10, 10, 48, "агент сам ловит PR или нужно создать ему тред?"),
            say(anna, 10, 10, 48, "Привет!", grouped = true),
            say(me, 10, 10, 51, "Привет! Сам ловит и PR, и изменения, но сейчас я его переделываю, может глючить"),
            say(anna, 10, 10, 51, "поняла, там 402-й срочный, если получится его протолкнуть, будет супер",
                reactions = listOf(MessageReaction("👀", 1, true, listOf(me)))),
            say(me, 10, 11, 4, "Я сейчас сделал ручной запуск плана после инцидента безопасности. План запускается в боевой среде, " +
                "поэтому сначала хочу посмотреть, кто автор PR и что он делает. Как закончу проверку, напишу сюда и в канал Infra PR Reviews."),
            say(anna, 10, 11, 4, "Принято"),
            day(1),
            say(me, 1, 10, 3, "Привет! А встреча по бюджету когда? Помню, ты говорила, но в календаре не вижу"),
            say(anna, 1, 10, 20, "в четверг в 15:00, сейчас пришлю приглашение"),
            day(0),
            say(me, 0, 9, 12, "спасибо!", reactions = listOf(MessageReaction("❤️", 1, false, listOf(anna)))),
        )
        val channel = listOf<ConversationRow>(
            day(1),
            say("@igor:example.org", 1, 18, 20, "Кто завтра дежурит по релизам?"),
            say(anna, 1, 18, 22, "я, с утра"),
            day(0),
            say("@deploy:example.org", 0, 9, 30, "Deploy 1.8.2 finished: 14 services, 0 failures")
                .copy(thread = MessageThread(3, "Игорь Соколов", at(0, 10, 10))),
            say("@igor:example.org", 0, 9, 41, "402-й смержил, спасибо за ревью",
                reactions = listOf(MessageReaction("🎉", 2, true, listOf(me, anna)))),
            say(anna, 0, 10, 51, "@Dmitry Ukhanov глянь, пожалуйста, 405-й до обеда"),
            say(anna, 0, 10, 52, "там миграция, лучше вдвоём посмотреть", grouped = true),
            say(me, 0, 10, 58, "Смотрю, через полчаса отпишусь"),
        )
        val actions = MessageActions(quick = listOf("👍", "❤️", "🙏", "👀", "😂"), recent = emptyList(), onReact = { _, _ -> },
            link = { "" }, onQuote = {}, onForward = {}, onMarkUnread = {}, onPin = { _, _ -> }, onSave = { _, _ -> })
        val text = "Отлично, приду с цифрами по инфре"
        val composer = if (screen == "Compose") ComposerState(text, loading = false,
            target = ComposerTarget.Reply("\$m9", "Анна Белова", "в четверг в 15:00, сейчас пришлю приглашение"),
            styles = listOf(ComposerStyle(text.indexOf("цифрами"), text.length, ComposerStyle.Kind.Bold)))
        else ComposerState(loading = false)
        val composerActions = ComposerActions(onAttach = {}, onFormat = { _, _, _, _ -> })
        when (screen) {
            "Channel" -> LiveChannelScreen(RoomSummary("!infra:example.org", "Infra PR Reviews", false, "", UnreadBadge.None, "I", 0,
                memberCount = 12), ConversationState(channel, me, loading = false, hasMore = false, names = people), ComposerState(loading = false),
                {}, {}, {}, {}, {}, {}, {}, {}, actions = actions, composerActions = composerActions)
            "Activity" -> LiveHomeScreen(me, RoomListState(loading = false), {}, {}, {}, activity = {
                fun item(id: String, who: String, kind: ActivityKind, room: String?, body: String, at: Long, unread: Boolean,
                    reactedTo: String? = null, thread: String? = null) = ActivityItem(id, "!$id:example.org", "\$$id", room ?: who,
                    room == null, who, AvatarPlaceholder.initials(who), AvatarPlaceholder.colorIndex(who), body, at, kind, thread,
                    reactedTo, unread)
                ActivityScreen(listOf(
                    item("a", "Анна Белова", ActivityKind.Mention, "Infra PR Reviews",
                        "@Dmitry Ukhanov глянь, пожалуйста, 405-й до обеда, там миграция", at(0, 10, 51), true),
                    item("b", "Игорь Соколов", ActivityKind.Reaction, null, "👍", at(0, 9, 40), true,
                        reactedTo = "выкатил фикс на стейджинг, проверь, когда будет минутка"),
                    item("c", "deploy agent", ActivityKind.ThreadReply, "Releases", "Deploy 1.8.2 finished: 14 services, 0 failures",
                        at(1, 18, 0), false, thread = "\$root"),
                    item("d", "Анна Белова", ActivityKind.Message, null, "в четверг в 15:00, сейчас пришлю приглашение", at(1, 10, 20), false),
                    item("e", "Ольга Нестерова", ActivityKind.Mention, "Design", "@Dmitry Ukhanov макеты онбординга готовы, посмотришь?",
                        at(2, 15, 0), false),
                ), {}, { _, _ -> })
            })
            else -> LiveChannelScreen(RoomSummary("!anna:example.org", "Анна Белова", true, "", UnreadBadge.None, "АБ",
                AvatarPlaceholder.colorIndex("Анна Белова"), memberCount = 2),
                ConversationState(dm, me, loading = false, hasMore = false, names = people), composer,
                {}, {}, {}, {}, {}, {}, {}, {}, actions = actions, composerActions = composerActions)
        }
    }

    companion object {
        @JvmStatic @Parameters(name = "{0} dark={1}")
        fun cases(): List<Array<Any>> = listOf("Chat", "Compose", "Menu", "Channel", "Activity").flatMap { screen ->
            listOf(arrayOf<Any>(screen, false), arrayOf<Any>(screen, true))
        }
    }
}
