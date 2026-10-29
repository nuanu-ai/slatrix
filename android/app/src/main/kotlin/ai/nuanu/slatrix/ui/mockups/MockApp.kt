package ai.nuanu.slatrix.ui.mockups

import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.NotificationsNone
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector

enum class MockScreen { Home, Dms, Activity, Channel, Thread, You }

@Composable
fun SlatrixMockups(
    dark: Boolean = true,
) {
    var screen by rememberSaveable { mutableStateOf(MockScreen.Home) }
    var tab by rememberSaveable { mutableStateOf(MockScreen.Home) }
    val stateHolder = rememberSaveableStateHolder()
    var threadReturn by rememberSaveable { mutableStateOf(MockScreen.Channel) }
    var roomId by rememberSaveable { mutableStateOf("design") }
    var palette by rememberSaveable { mutableStateOf(SidebarPalette.Aubergine) }
    var darkOverride by rememberSaveable { mutableStateOf<Int?>(null) }
    var drafts by rememberSaveable { mutableStateOf(mapOf<String, String>()) }
    var sentByRoom by rememberSaveable { mutableStateOf(mapOf<String, List<MockMessage>>()) }
    var reactions by rememberSaveable { mutableStateOf(emptyList<String>()) }
    val onReaction: (String) -> Unit = { id -> reactions = if (id in reactions) reactions - id else reactions + id }
    val withReaction: (MockMessage) -> MockMessage = { it.copy(reacted = it.id in reactions) }
    var sentReplies by rememberSaveable { mutableStateOf(emptyList<MockMessage>()) }
    val effectiveDark = darkOverride?.let { it == 1 } ?: dark
    val room = MockData.channels.firstOrNull { it.id == roomId } ?: MockData.conversations.first { it.id == roomId }.let {
        MockChannel(it.id, it.name, "Direct message", direct = true)
    }
    val messages = if (room.direct) {
        val conversation = MockData.conversations.first { it.id == roomId }
        listOf(MockMessage("dm-${conversation.id}", conversation.name, conversation.initials, conversation.time, conversation.preview, conversation.colorIndex))
    } else MockData.messages.map { message ->
        if (message.id == MockData.threadParent.id) message.copy(replyCount = MockData.replies.size + sentReplies.size) else message
    }
    val visibleMessages = (messages + sentByRoom[roomId].orEmpty()).map(withReaction)
    val back: () -> Unit = { screen = if (screen == MockScreen.Thread) threadReturn else tab }
    BackHandler(enabled = screen !in rootScreens, onBack = back)

    SlatrixTheme(dark = effectiveDark, palette = palette) {
        val colors = SlatrixTheme.colors
        Surface(Modifier.fillMaxSize(), color = colors.canvas) {
            BoxWithConstraints(Modifier.navigationBarsPadding()) {
                val expanded = maxWidth >= UiMetrics.ExpandedWidth
                val root = screen in rootScreens
                Row(Modifier.fillMaxSize()) {
                    if (root && expanded) {
                        NavigationRail(containerColor = colors.raised) {
                            rootScreens.forEach { destination ->
                                NavigationRailItem(
                                    selected = screen == destination,
                                    onClick = { tab = destination; screen = destination },
                                    icon = { Icon(destination.icon(), contentDescription = null) },
                                    label = { Text(destination.label()) },
                                    colors = NavigationRailItemDefaults.colors(selectedIconColor = colors.textPrimary, selectedTextColor = colors.textPrimary, indicatorColor = colors.selection, unselectedIconColor = colors.textSecondary, unselectedTextColor = colors.textSecondary),
                                )
                            }
                        }
                    }
                    Column(Modifier.weight(1f)) {
                        Box(Modifier.weight(1f)) {
                            stateHolder.SaveableStateProvider(if (screen == MockScreen.Channel) "channel:$roomId" else screen.name) {
                            when (screen) {
                                MockScreen.Home -> SlackHomeScreen(MockData.channels,
                                    conversations = MockData.conversations, onDm = { roomId = it; screen = MockScreen.Channel },
                                    onChannel = { roomId = it; screen = MockScreen.Channel },
                                    onThread = { threadReturn = screen; roomId = "design"; screen = MockScreen.Thread },
                                    onYou = { screen = MockScreen.You })
                                MockScreen.Dms -> SlackDmsScreen(MockData.conversations,
                                    onOpen = { roomId = it; screen = MockScreen.Channel },
                                    onYou = { screen = MockScreen.You })
                                MockScreen.Activity -> SlackActivityScreen(MockData.activity,
                                    onThread = { threadReturn = screen; roomId = "design"; screen = MockScreen.Thread },
                                    onYou = { screen = MockScreen.You })
                                MockScreen.Channel -> SlackChannelScreen(room, visibleMessages, onReaction = onReaction,
                                    draft = drafts["channel:$roomId"].orEmpty(),
                                    onDraft = { drafts = drafts + ("channel:$roomId" to it) },
                                    onSend = {
                                        val key = "channel:$roomId"
                                        val text = drafts[key].orEmpty()
                                        if (text.isNotBlank()) {
                                            val sent = sentByRoom[roomId].orEmpty()
                                            sentByRoom = sentByRoom + (roomId to (sent + ownMessage("sent-$roomId-${sent.size}", text)))
                                            drafts = drafts - key
                                        }
                                    }, onThread = { threadReturn = screen; screen = MockScreen.Thread }, onBack = back)
                                MockScreen.Thread -> SlackThreadScreen(withReaction(MockData.threadParent), (MockData.replies + sentReplies).map(withReaction), onReaction = onReaction,
                                    draft = drafts["thread:${MockData.threadParent.id}"].orEmpty(),
                                    onDraft = { drafts = drafts + ("thread:${MockData.threadParent.id}" to it) },
                                    onSend = {
                                        val key = "thread:${MockData.threadParent.id}"
                                        val text = drafts[key].orEmpty()
                                        if (text.isNotBlank()) {
                                            sentReplies = sentReplies + ownMessage("local-reply-${sentReplies.size}", text)
                                            drafts = drafts - key
                                        }
                                    }, onBack = back)
                                MockScreen.You -> YouScreen(effectiveDark, palette,
                                    onDarkToggle = { darkOverride = if (effectiveDark) 0 else 1 },
                                    onPalette = { palette = it }, onBack = back)
                            }
                            }
                        }
                        if (root && !expanded) {
                            NavigationBar(containerColor = colors.raised) {
                                rootScreens.forEach { destination ->
                                    NavigationBarItem(
                                        selected = screen == destination,
                                        onClick = { tab = destination; screen = destination },
                                        icon = { Icon(destination.icon(), contentDescription = null) },
                                        label = { Text(destination.label()) },
                                        colors = NavigationBarItemDefaults.colors(
                                            selectedIconColor = colors.textPrimary,
                                            selectedTextColor = colors.textPrimary,
                                            indicatorColor = colors.selection,
                                            unselectedIconColor = colors.textSecondary,
                                            unselectedTextColor = colors.textSecondary,
                                        ),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private val rootScreens = listOf(MockScreen.Home, MockScreen.Dms, MockScreen.Activity)
private fun MockScreen.label() = when (this) {
    MockScreen.Home -> "Home"
    MockScreen.Dms -> "DMs"
    else -> "Activity"
}
private fun MockScreen.icon(): ImageVector = when (this) {
    MockScreen.Home -> Icons.Outlined.Home
    MockScreen.Dms -> Icons.Outlined.ChatBubbleOutline
    else -> Icons.Outlined.NotificationsNone
}

private fun ownMessage(id: String, body: String) = MockMessage(
    id, MockData.profile.name, MockData.profile.initials, "Just now", body,
)
