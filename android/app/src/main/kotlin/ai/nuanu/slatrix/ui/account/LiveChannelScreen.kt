package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import java.text.DateFormat
import java.util.Date

@Composable
fun LiveChannelScreen(room: RoomSummary, state: ConversationState, composer: ComposerState,
    onDraft: (String) -> Unit, onSend: () -> Unit, onBack: () -> Unit, onLoadOlder: () -> Unit, onRead: (String) -> Unit) {
    val colors = SlatrixTheme.colors
    val list = rememberLazyListState()
    BackHandler(onBack = onBack)
    Column(Modifier.fillMaxSize().background(colors.canvas).navigationBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(end = UiMetrics.GapLarge,
            top = UiMetrics.GapSmall, bottom = UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") }
            Surface(Modifier.weight(1f), shape = MaterialTheme.shapes.extraLarge, color = colors.raised) {
                Row(Modifier.heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapMedium, vertical = UiMetrics.GapTiny),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                    if (!room.direct) Icon(Icons.Outlined.Tag, null, Modifier.size(UiMetrics.Icon))
                    Column {
                        Text(room.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (room.topic.isNotBlank()) Text(room.topic, style = MaterialTheme.typography.bodyMedium,
                            color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
        HorizontalDivider(color = colors.border)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            LazyColumn(Modifier.fillMaxSize(), state = list, reverseLayout = true,
                contentPadding = PaddingValues(vertical = UiMetrics.GapSmall)) {
                items(state.messages.asReversed(), key = { it.id }) { message -> LiveMessageRow(message) }
                if (state.hasMore) item {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        TextButton(onClick = onLoadOlder, enabled = !state.loading && !state.loadingHistory) { Text("Earlier messages") }
                    }
                }
            }
            if (state.loading || state.loadingHistory) Box(Modifier.align(Alignment.TopCenter)) { ConnectionIndicator(true, null) }
            (composer.error ?: state.sendError ?: state.error)?.let { message ->
                Snackbar(Modifier.align(Alignment.BottomCenter).padding(UiMetrics.GapLarge)) { Text(message) }
            }
        }
        val description = if (room.direct) "Message ${room.name}" else "Message #${room.name}"
        Surface(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ComposerMinHeight),
            shape = MaterialTheme.shapes.extraLarge, color = colors.canvas, border = BorderStroke(UiMetrics.Divider, colors.border)) {
            Column(Modifier.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapTiny)) {
                BasicTextField(composer.text, onDraft, enabled = !composer.loading,
                    modifier = Modifier.fillMaxWidth().heightIn(min = UiMetrics.ComposerFieldMinHeight).semantics { contentDescription = description },
                    textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.textBody),
                    cursorBrush = SolidColor(colors.accent), maxLines = 5,
                    decorationBox = { inner ->
                        Box(contentAlignment = Alignment.CenterStart) {
                            if (composer.text.isEmpty()) Text(description, style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
                            inner()
                        }
                    })
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    IconButton(onClick = onSend, enabled = !composer.loading && !composer.sending && composer.text.isNotBlank()) {
                        Icon(Icons.AutoMirrored.Outlined.Send, "Send message", tint = if (composer.text.isNotBlank()) colors.accent else colors.textTertiary)
                    }
                }
            }
        }
    }
}

@Composable
private fun LiveMessageRow(message: ConversationMessage) {
    val colors = SlatrixTheme.colors
    val time = remember(message.timestamp) { DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(message.timestamp)) }
    Row(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        LiveAvatar(message.initials, message.colorIndex)
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(message.senderName, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(when (message.sendState) { MessageSendState.Sent -> time; MessageSendState.Sending -> "Sending…"; MessageSendState.Failed -> "Not sent" },
                    style = MaterialTheme.typography.bodySmall, maxLines = 1,
                    color = if (message.sendState == MessageSendState.Failed) colors.destructive else colors.textSecondary)
            }
            SelectionContainer { Text(message.body, style = MaterialTheme.typography.bodyLarge, color = colors.textBody) }
        }
    }
}
