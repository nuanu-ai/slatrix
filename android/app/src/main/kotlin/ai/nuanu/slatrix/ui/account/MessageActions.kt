package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.MatrixComposer
import ai.nuanu.slatrix.core.EmojiRecents
import ai.nuanu.slatrix.core.MatrixConversation
import ai.nuanu.slatrix.core.MatrixWorkspace
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.content.ClipData
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AddReaction
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FormatQuote
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.MarkChatUnread
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Title
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.launch

/** What the message sheet can do; an action left null isn't offered. */
data class MessageActions(
    /** The one-tap reactions, best first. */
    val quick: List<String> = emptyList(),
    val recent: List<String> = emptyList(),
    val onReact: ((ConversationMessage, String) -> Unit)? = null,
    val link: (suspend (ConversationMessage) -> String?)? = null,
    val onQuote: ((ConversationMessage) -> Unit)? = null,
    val onEdit: ((ConversationMessage) -> Unit)? = null,
    val onDelete: ((ConversationMessage) -> Unit)? = null,
    val onMarkUnread: ((ConversationMessage) -> Unit)? = null,
)

/** Slack Android's sheet holds five, beside Add reaction. */
private const val QUICK_REACTIONS = 5

private val textKinds = setOf(MessageKind.Text, MessageKind.Notice, MessageKind.Emote)

/** Slack's long-press sheet, the emoji picker it opens and the delete confirmation, one after another. */
@Composable
internal fun MessageActionsHost(message: ConversationMessage, actions: MessageActions, onOpenThread: ((String) -> Unit)?,
    onRetrySend: (ConversationMessage) -> Unit, onDeleteUnsent: (ConversationMessage) -> Unit, onDismiss: () -> Unit) {
    var step by remember(message.id) { mutableStateOf(Step.Sheet) }
    when (step) {
        Step.Sheet -> MessageActionSheet(message, actions, onOpenThread, onRetrySend, onDeleteUnsent, { step = it }, onDismiss)
        Step.Picker -> EmojiPickerSheet(actions.recent, { emoji -> actions.onReact?.invoke(message, emoji); onDismiss() }, onDismiss)
        Step.ConfirmDelete -> AlertDialog(onDismissRequest = onDismiss,
            title = { Text("Delete message") },
            text = { Text("Are you sure you want to delete this message? This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = { actions.onDelete?.invoke(message); onDismiss() }) {
                    Text("Delete", color = SlatrixTheme.colors.destructive)
                }
            },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
            containerColor = SlatrixTheme.colors.overlay)
    }
}

private enum class Step { Sheet, Picker, ConfirmDelete }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MessageActionSheet(message: ConversationMessage, actions: MessageActions, onOpenThread: ((String) -> Unit)?,
    onRetrySend: (ConversationMessage) -> Unit,
    onDeleteUnsent: (ConversationMessage) -> Unit, onStep: (Step) -> Unit, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    val eventId = message.eventId.takeIf { message.sendState == MessageSendState.Sent && message.kind != MessageKind.Deleted }
    fun copy(text: String) = scope.launch {
        clipboard.setClipEntry(ClipEntry(ClipData.newPlainText(message.senderName, text)))
        onDismiss()
    }
    ModalBottomSheet(onDismissRequest = onDismiss, shape = SlatrixTheme.topPanelShape, containerColor = colors.canvas) {
        Column(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapLarge)) {
            Row(Modifier.padding(horizontal = UiMetrics.GapLarge).padding(bottom = UiMetrics.GapSmall),
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall), verticalAlignment = Alignment.CenterVertically) {
                Text(message.senderName, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Bold, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("${dayLabel(message.timestamp)} at ${timeLabel(message.timestamp)}",
                    style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1)
            }
            val react = actions.onReact
            if (eventId != null && react != null) {
                Row(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapMedium),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge, Alignment.CenterHorizontally)) {
                    actions.quick.forEach { emoji ->
                        Round("React with $emoji", { react(message, emoji); onDismiss() }) {
                            Text(emoji, style = MaterialTheme.typography.titleLarge)
                        }
                    }
                    Round("Add reaction", { onStep(Step.Picker) }) {
                        Icon(Icons.Outlined.AddReaction, null, Modifier.size(UiMetrics.SheetIcon), tint = colors.textPrimary)
                    }
                }
            }
            val quote = actions.onQuote
            if (eventId != null && (onOpenThread != null || quote != null)) {
                Row(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge).padding(bottom = UiMetrics.GapSmall),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                    if (onOpenThread != null) ActionTile(Icons.Outlined.ChatBubbleOutline, "Reply", Modifier.weight(1f)) {
                        onOpenThread(eventId); onDismiss()
                    }
                    if (quote != null) ActionTile(Icons.Outlined.FormatQuote, "Quote", Modifier.weight(1f)) { quote(message); onDismiss() }
                }
            }
            if (message.sendState == MessageSendState.Failed) {
                if (message.canRetry) SheetAction(Icons.Outlined.Refresh, "Retry", colors.textPrimary) { onRetrySend(message); onDismiss() }
                SheetAction(Icons.Outlined.Delete, "Delete message", colors.destructive) { onDeleteUnsent(message); onDismiss() }
            }
            val markUnread = actions.onMarkUnread
            if (eventId != null && markUnread != null) SheetAction(Icons.Outlined.MarkChatUnread, "Mark unread", colors.textPrimary) {
                markUnread(message); onDismiss()
            }
            val link = actions.link
            if (eventId != null && link != null) SheetAction(Icons.Outlined.Link, "Copy link to message", colors.textPrimary) {
                scope.launch { link(message)?.let { copy(it) } ?: onDismiss() }
            }
            if (message.kind in textKinds) SheetAction(Icons.Outlined.Title, "Copy message", colors.textPrimary) { copy(message.body) }
            val edit = actions.onEdit?.takeIf { message.editable }
            val delete = eventId != null && message.own && actions.onDelete != null
            if (eventId != null && (edit != null || delete)) {
                HorizontalDivider(Modifier.padding(vertical = UiMetrics.GapSmall), color = colors.border)
                if (edit != null) SheetAction(Icons.Outlined.Edit, "Edit message", colors.textPrimary) { edit(message); onDismiss() }
                if (delete) SheetAction(Icons.Outlined.Delete, "Delete message", colors.destructive) { onStep(Step.ConfirmDelete) }
            }
        }
    }
}

@Composable
private fun Round(description: String, onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(Modifier.size(UiMetrics.Touch).background(SlatrixTheme.colors.raised, CircleShape)
        .clickable(role = Role.Button, onClick = onClick).semantics { contentDescription = description },
        contentAlignment = Alignment.Center) { content() }
}

@Composable
private fun ActionTile(icon: ImageVector, label: String, modifier: Modifier, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Column(modifier.height(UiMetrics.ActionTile).background(colors.raised, MaterialTheme.shapes.large)
        .clickable(role = Role.Button, onClick = onClick),
        verticalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, Modifier.size(UiMetrics.SheetIcon), tint = colors.textPrimary)
        Text(label, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = colors.textPrimary)
    }
}

@Composable
private fun SheetAction(icon: ImageVector, label: String, color: Color, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(onClick = onClick).padding(horizontal = UiMetrics.GapLarge),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(UiMetrics.SheetIcon), tint = color)
        Text(label, style = MaterialTheme.typography.bodyLarge, color = color)
    }
}

/** The sheet's actions on an open conversation; reacting also moves the emoji up your recent list. */
@Composable
internal fun rememberMessageActions(conversation: MatrixConversation?, composer: MatrixComposer?, workspace: MatrixWorkspace?): MessageActions {
    val recent = workspace?.emojiHistory?.state?.collectAsState()?.value.orEmpty()
    return remember(conversation, composer, workspace, recent) {
        if (conversation == null) return@remember MessageActions()
        MessageActions(
            quick = EmojiRecents.quick(recent, QUICK_REACTIONS), recent = recent,
            onReact = { message, emoji -> conversation.react(message, emoji) { workspace?.emojiHistory?.use(emoji) } },
            link = conversation::link,
            onDelete = conversation::delete,
            onQuote = { message -> ComposerTarget.reply(message)?.let { composer?.reply(it) } },
            onEdit = { message -> ComposerTarget.edit(message)?.let { composer?.editMessage(it) } },
        )
    }
}
