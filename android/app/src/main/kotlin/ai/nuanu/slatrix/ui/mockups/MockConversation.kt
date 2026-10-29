package ai.nuanu.slatrix.ui.mockups

import ai.nuanu.slatrix.ui.designsystem.AvatarStyle
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material.icons.outlined.ThumbUp
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow

@Composable
fun SlackChannelScreen(
    channel: MockChannel,
    messages: List<MockMessage>,
    draft: String,
    onDraft: (String) -> Unit,
    onSend: () -> Unit,
    onThread: () -> Unit,
    onBack: () -> Unit,
) {
    val listState = rememberLazyListState()
    var previousCount by remember(channel.id) { mutableStateOf(messages.size) }
    LaunchedEffect(channel.id, messages.size) {
        if (messages.size > previousCount) listState.scrollToItem(messages.size)
        previousCount = messages.size
    }
    Column(Modifier.fillMaxSize().background(SlatrixTheme.colors.canvas).imePadding()) {
        ConversationHeader(channel.name, channel.topic, onBack, channel = !channel.direct)
        LazyColumn(Modifier.weight(1f), state = listState) {
            item { ConversationDate("Today") }
            items(messages, key = { it.id }) { ConversationMessage(it, onThread) }
        }
        ConversationComposer(
            draft, onDraft, onSend,
            if (channel.direct) "Message ${channel.name}" else "Message #${channel.name}",
            "Send message",
        )
    }
}

@Composable
fun SlackThreadScreen(
    parent: MockMessage,
    replies: List<MockMessage>,
    draft: String,
    onDraft: (String) -> Unit,
    onSend: () -> Unit,
    onBack: () -> Unit,
) {
    val listState = rememberLazyListState()
    var previousCount by remember(parent.id) { mutableStateOf(replies.size) }
    LaunchedEffect(parent.id, replies.size) {
        if (replies.size > previousCount) listState.scrollToItem(replies.size + 1)
        previousCount = replies.size
    }
    Column(Modifier.fillMaxSize().background(SlatrixTheme.colors.canvas).imePadding()) {
        ConversationHeader("Thread", "# design", onBack, raised = false)
        LazyColumn(Modifier.weight(1f), state = listState) {
            item { ConversationMessage(parent.copy(replyCount = 0), {}, expanded = true) }
            item {
                HorizontalDivider(color = SlatrixTheme.colors.border)
                Row(
                    Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapLarge),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.ChatBubbleOutline, null, Modifier.size(UiMetrics.Icon), tint = SlatrixTheme.colors.textSecondary)
                    Text(if (replies.isEmpty()) "Reply in thread" else "${replies.size} replies", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                }
                HorizontalDivider(color = SlatrixTheme.colors.border)
            }
            items(replies, key = { it.id }) { ConversationMessage(it, {}) }
        }
        ConversationComposer(draft, onDraft, onSend, "Reply…", "Send reply")
    }
}

@Composable
private fun ConversationHeader(title: String, subtitle: String, onBack: () -> Unit, channel: Boolean = false, raised: Boolean = true) {
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().padding(end = UiMetrics.GapLarge, top = UiMetrics.GapSmall, bottom = UiMetrics.GapSmall),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack, modifier = Modifier.size(UiMetrics.Touch)) {
            Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back")
        }
        Surface(Modifier.weight(1f), shape = MaterialTheme.shapes.extraLarge, color = if (raised) SlatrixTheme.colors.raised else SlatrixTheme.colors.canvas) {
            Row(
                Modifier.heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapTiny),
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (channel) Icon(Icons.Outlined.Tag, null, Modifier.size(UiMetrics.Icon))
                Column(Modifier.weight(1f)) {
                    Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = SlatrixTheme.colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
    HorizontalDivider(color = SlatrixTheme.colors.border)
}

@Composable
private fun ConversationDate(label: String) {
    Box(Modifier.fillMaxWidth().padding(vertical = UiMetrics.GapMedium), contentAlignment = Alignment.Center) {
        HorizontalDivider(color = SlatrixTheme.colors.border)
        Surface(shape = MaterialTheme.shapes.extraLarge, color = SlatrixTheme.colors.canvas, border = BorderStroke(UiMetrics.Divider, SlatrixTheme.colors.border)) {
            Text(
                label, Modifier.padding(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapTiny),
                style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold,
                color = SlatrixTheme.colors.textSecondary,
            )
        }
    }
}

@Composable
private fun ConversationMessage(message: MockMessage, onThread: () -> Unit, expanded: Boolean = false) {
    Column(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall)) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge),
        ) {
            Box(
                Modifier.size(UiMetrics.Avatar).clip(MaterialTheme.shapes.large).background(DesignTokens.avatarColors[message.colorIndex]),
                contentAlignment = Alignment.Center,
            ) {
                Text(message.initials, style = AvatarStyle.label, fontWeight = FontWeight.Bold, color = SlatrixTheme.colors.onAccent)
            }
            Column(Modifier.weight(1f)) {
                if (expanded) {
                    Text(message.author, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
                    Text(message.time, style = MaterialTheme.typography.bodyMedium, color = SlatrixTheme.colors.textSecondary)
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                        Text(message.author, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(message.time, style = MaterialTheme.typography.bodyMedium, color = SlatrixTheme.colors.textSecondary)
                    }
                    Text(message.body, style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textBody)
                    MessageActions(message, onThread)
                }
            }
        }
        if (expanded) {
            Spacer(Modifier.height(UiMetrics.GapLarge))
            Text(message.body, style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textBody)
            MessageActions(message, onThread)
        }
    }
}

@Composable
private fun MessageActions(message: MockMessage, onThread: () -> Unit) {
    var reacted by rememberSaveable(message.id) { mutableStateOf(false) }
    if (message.reaction != null || message.replyCount > 0) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
            message.reaction?.let { count ->
                Box(
                    Modifier.sizeIn(minWidth = UiMetrics.Touch, minHeight = UiMetrics.Touch)
                        .clickable(role = Role.Button, onClickLabel = if (reacted) "Remove thumbs up reaction" else "Add thumbs up reaction") { reacted = !reacted },
                    contentAlignment = Alignment.Center,
                ) {
                    Surface(color = if (reacted) SlatrixTheme.colors.selection else SlatrixTheme.colors.raised, shape = MaterialTheme.shapes.extraLarge) {
                        Row(Modifier.padding(horizontal = UiMetrics.GapSmall, vertical = UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.ThumbUp, if (reacted) "Remove thumbs up reaction" else "Add thumbs up reaction", Modifier.size(UiMetrics.IconSmall), tint = SlatrixTheme.colors.accent)
                            Spacer(Modifier.width(UiMetrics.GapTiny))
                            Text((count.toInt() + if (reacted) 1 else 0).toString(), style = MaterialTheme.typography.labelLarge)
                        }
                    }
                }
            }
            if (message.replyCount > 0) {
                Row(
                    Modifier.heightIn(min = UiMetrics.Touch).clickable(role = Role.Button, onClick = onThread),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.ChatBubbleOutline, null, Modifier.size(UiMetrics.IconSmall), tint = SlatrixTheme.colors.accent)
                    Spacer(Modifier.width(UiMetrics.GapTiny))
                    Text("${message.replyCount} replies", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = SlatrixTheme.colors.accent)
                }
            }
        }
    }
}

@Composable
private fun ConversationComposer(draft: String, onDraft: (String) -> Unit, onSend: () -> Unit, placeholder: String, sendDescription: String) {
    var focused by remember { mutableStateOf(false) }
    Surface(
        modifier = Modifier.fillMaxWidth().heightIn(min = UiMetrics.ComposerMinHeight),
        shape = MaterialTheme.shapes.extraLarge,
        color = SlatrixTheme.colors.canvas,
        border = BorderStroke(UiMetrics.Divider, SlatrixTheme.colors.border),
    ) {
        Column(Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapTiny)) {
            BasicTextField(
                value = draft,
                onValueChange = onDraft,
                modifier = Modifier.fillMaxWidth().heightIn(min = UiMetrics.ComposerFieldMinHeight).onFocusChanged { focused = it.isFocused },
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = SlatrixTheme.colors.textBody),
                cursorBrush = SolidColor(SlatrixTheme.colors.accent),
                maxLines = 5,
                decorationBox = { innerTextField ->
                    Box(contentAlignment = Alignment.CenterStart) {
                        if (draft.isEmpty()) Text(placeholder, style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary)
                        innerTextField()
                    }
                },
            )
            if (focused || draft.isNotEmpty()) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    IconButton(onClick = onSend, enabled = draft.isNotBlank(), modifier = Modifier.size(UiMetrics.Touch)) {
                        Icon(Icons.AutoMirrored.Outlined.Send, sendDescription, tint = if (draft.isNotBlank()) SlatrixTheme.colors.accent else SlatrixTheme.colors.textTertiary)
                    }
                }
            }
        }
    }
}
