package ai.nuanu.slatrix.ui.mockups

import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SidebarPalette
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material.icons.outlined.ThumbUp
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp

@Composable
fun HomeScreen(channels: List<MockChannel>, onChannel: (String) -> Unit, onThread: () -> Unit, onYou: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    var unread by rememberSaveable { mutableStateOf(false) }
    val visible = channels.filter { it.name.contains(query, ignoreCase = true) && (!unread || it.unread) }
    Column(Modifier.fillMaxSize().background(SlatrixTheme.colors.canvas)) {
        ScreenHeader("Studio", onYou = onYou)
        SearchBox(query, { query = it }, "Search Studio")
        Row(Modifier.padding(horizontal = UiMetrics.GapLarge), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
            FilterChip(selected = !unread, onClick = { unread = false }, label = { Text("All") })
            FilterChip(selected = unread, onClick = { unread = true }, label = { Text("Unread") })
        }
        LazyColumn {
            item {
                Row(
                    Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(onClick = onThread)
                        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Forum, null, Modifier.size(UiMetrics.Icon), tint = SlatrixTheme.colors.textSecondary)
                    Text("Threads", Modifier.weight(1f).padding(start = UiMetrics.GapMedium), style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                    CountBadge("2")
                }
            }
            item { SectionLabel("Channels") }
            items(visible, key = { it.id }) { channel ->
                Row(
                    Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable { onChannel(channel.id) }
                        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Tag, null, Modifier.size(UiMetrics.Icon), tint = SlatrixTheme.colors.textSecondary)
                    Text(channel.name, Modifier.weight(1f).padding(start = UiMetrics.GapMedium), style = MaterialTheme.typography.bodyLarge, fontWeight = if (channel.unread) FontWeight.Bold else FontWeight.Normal)
                    channel.badge?.let { CountBadge(it) }
                }
            }
            if (visible.isEmpty()) item { EmptyResults() }
        }
    }
}

@Composable
fun DmsScreen(conversations: List<MockConversation>, onOpen: (String) -> Unit, onYou: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    val visible = conversations.filter { it.name.contains(query, ignoreCase = true) || it.preview.contains(query, ignoreCase = true) }
    Column(Modifier.fillMaxSize().background(SlatrixTheme.colors.canvas)) {
        ScreenHeader("DMs", onYou = onYou)
        SearchBox(query, { query = it }, "Search DMs")
        LazyColumn {
            items(visible, key = { it.id }) { conversation ->
                Row(
                    Modifier.fillMaxWidth().clickable { onOpen(conversation.id) }.padding(UiMetrics.GapLarge),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium),
                ) {
                    Avatar(conversation.initials, conversation.colorIndex, UiMetrics.LargeAvatar)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                            Text(conversation.name, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                            Text(conversation.time, style = MaterialTheme.typography.labelSmall, color = SlatrixTheme.colors.textSecondary)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                            Text(conversation.preview, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = if (conversation.badge == null) SlatrixTheme.colors.textSecondary else SlatrixTheme.colors.textBody, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            conversation.badge?.let { CountBadge(it) }
                        }
                    }
                }
                HorizontalDivider(color = SlatrixTheme.colors.border, modifier = Modifier.padding(start = UiMetrics.LargeAvatar + UiMetrics.GapLarge + UiMetrics.GapMedium))
            }
            if (visible.isEmpty()) item { EmptyResults() }
        }
    }
}

@Composable
fun ActivityScreen(items: List<MockActivity>, onThread: () -> Unit, onYou: () -> Unit) {}

@Composable
fun ChannelScreen(channel: MockChannel, messages: List<MockMessage>, draft: String, onDraft: (String) -> Unit, onSend: () -> Unit, onThread: () -> Unit, onBack: () -> Unit) {
    Column(Modifier.fillMaxSize().background(SlatrixTheme.colors.canvas).imePadding()) {
        ScreenHeader(if (channel.direct) channel.name else "# ${channel.name}", onBack = onBack, subtitle = channel.topic)
        LazyColumn(Modifier.weight(1f)) {
            item {
                Column(Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSection), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                    Text(if (channel.direct) channel.name else "# ${channel.name}", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    Text(channel.topic, style = MaterialTheme.typography.bodyMedium, color = SlatrixTheme.colors.textSecondary)
                }
                DateDivider("Today")
            }
            items(messages, key = { it.id }) { MessageRow(it, onThread) }
        }
        Composer(draft, onDraft, onSend, if (channel.direct) "Message ${channel.name}" else "Message #${channel.name}", "Send message")
    }
}

@Composable
fun ThreadScreen(parent: MockMessage, replies: List<MockMessage>, draft: String, onDraft: (String) -> Unit, onSend: () -> Unit, onBack: () -> Unit) {}

@Composable
fun YouScreen(dark: Boolean, palette: SidebarPalette, onDarkToggle: () -> Unit, onPalette: (SidebarPalette) -> Unit, onBack: () -> Unit) {}

@Composable
private fun ScreenHeader(title: String, onYou: (() -> Unit)? = null, onBack: (() -> Unit)? = null, subtitle: String? = null) {
    Row(
        Modifier.fillMaxWidth().background(SlatrixTheme.colors.frame).statusBarsPadding().padding(horizontal = UiMetrics.GapSmall, vertical = UiMetrics.GapTiny),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) IconButton(onClick = onBack, modifier = Modifier.size(UiMetrics.Touch)) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") }
        Column(Modifier.weight(1f).padding(horizontal = UiMetrics.GapSmall, vertical = UiMetrics.GapSmall)) {
            Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            subtitle?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = SlatrixTheme.colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        if (onYou != null) IconButton(onClick = onYou, modifier = Modifier.size(UiMetrics.Touch).semantics { contentDescription = "You" }) { Avatar("JL", 0) }
    }
}

@Composable
private fun SearchBox(query: String, onQuery: (String) -> Unit, placeholder: String) {
    OutlinedTextField(
        query, onQuery, Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        placeholder = { Text(placeholder, style = MaterialTheme.typography.bodyMedium) },
        leadingIcon = { Icon(Icons.Outlined.Search, null) }, singleLine = true, shape = MaterialTheme.shapes.large,
    )
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, Modifier.padding(start = UiMetrics.GapLarge, end = UiMetrics.GapLarge, top = UiMetrics.SectionTop, bottom = UiMetrics.GapSmall), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = SlatrixTheme.colors.textSecondary)
}

@Composable
private fun Avatar(initials: String, colorIndex: Int, size: Dp = UiMetrics.Avatar) {
    Box(Modifier.size(size).clip(MaterialTheme.shapes.large).background(DesignTokens.avatarColors[colorIndex]), contentAlignment = Alignment.Center) {
        Text(initials, style = if (size == UiMetrics.ProfileAvatar) MaterialTheme.typography.headlineMedium else MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = SlatrixTheme.colors.onAccent)
    }
}

@Composable
private fun CountBadge(text: String) {
    Surface(color = SlatrixTheme.colors.mention, contentColor = SlatrixTheme.colors.onAccent, shape = MaterialTheme.shapes.large) {
        Box(Modifier.heightIn(min = UiMetrics.BadgeMin).padding(horizontal = UiMetrics.GapSmall), contentAlignment = Alignment.Center) {
            Text(text, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Bold)
        }
    }
}

@Composable
private fun DateDivider(label: String) {
    Row(Modifier.padding(vertical = UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        HorizontalDivider(Modifier.weight(1f), color = SlatrixTheme.colors.border)
        Text(label, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = SlatrixTheme.colors.textSecondary)
        HorizontalDivider(Modifier.weight(1f), color = SlatrixTheme.colors.border)
    }
}

@Composable
private fun MessageRow(message: MockMessage, onThread: () -> Unit) {
    var reacted by remember(message.id) { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapMedium), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
        Avatar(message.initials, message.colorIndex)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(message.author, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                Text(message.time, style = MaterialTheme.typography.labelSmall, color = SlatrixTheme.colors.textSecondary)
            }
            Text(message.body, style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textBody)
            message.reaction?.let { count ->
                TextButton(onClick = { reacted = !reacted }) {
                    Icon(Icons.Outlined.ThumbUp, if (reacted) "Remove thumbs up reaction" else "Add thumbs up reaction", Modifier.size(UiMetrics.IconSmall))
                    Spacer(Modifier.width(UiMetrics.GapTiny))
                    Text((count.toInt() + if (reacted) 1 else 0).toString(), style = MaterialTheme.typography.labelMedium)
                }
            }
            if (message.replyCount > 0) TextButton(onClick = onThread) {
                Icon(Icons.Outlined.ChatBubbleOutline, null, Modifier.size(UiMetrics.IconSmall))
                Spacer(Modifier.width(UiMetrics.GapSmall))
                Text("${message.replyCount} replies", style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

@Composable
private fun Composer(draft: String, onDraft: (String) -> Unit, onSend: () -> Unit, placeholder: String, sendDescription: String) {
    HorizontalDivider(color = SlatrixTheme.colors.border)
    OutlinedTextField(
        draft, onDraft, Modifier.fillMaxWidth().padding(UiMetrics.GapMedium),
        placeholder = { Text(placeholder, style = MaterialTheme.typography.bodyLarge) },
        trailingIcon = { IconButton(onClick = onSend, enabled = draft.isNotBlank(), modifier = Modifier.size(UiMetrics.Touch)) { Icon(Icons.AutoMirrored.Outlined.Send, sendDescription) } },
        minLines = 1, maxLines = 5, shape = MaterialTheme.shapes.large,
    )
}

@Composable
private fun EmptyResults() {
    Text("No results", Modifier.padding(UiMetrics.GapSection), style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary)
}
