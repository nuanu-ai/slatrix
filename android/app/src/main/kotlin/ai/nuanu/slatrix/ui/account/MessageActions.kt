package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.ConversationMessage
import ai.nuanu.slatrix.core.MatrixComposer
import ai.nuanu.slatrix.core.EmojiRecents
import ai.nuanu.slatrix.core.MatrixConversation
import ai.nuanu.slatrix.core.MatrixWorkspace
import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.core.MessageKind
import ai.nuanu.slatrix.core.MessageSendState
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.BottomSheet
import ai.nuanu.slatrix.ui.designsystem.MenuItem
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.content.ClipData
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AddReaction
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.FormatQuote
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Title
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import kotlinx.coroutines.CoroutineScope
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
    /** Marks the conversation unread; Matrix keeps no unread point inside it, so it doesn't take the message. */
    val onMarkUnread: (() -> Unit)? = null,
    /** Opens the conversation picker that forwards the message. */
    val onForward: ((ConversationMessage) -> Unit)? = null,
    /** The room's pinned messages, which the sheet offers to unpin; [onPin] is null where you may not pin. */
    val pinned: Set<String> = emptySet(),
    val onPin: ((ConversationMessage, pin: Boolean) -> Unit)? = null,
    /** What the room is called in Pin to channel. */
    val place: String = "channel",
    /** Sets your media's caption; null removes it. */
    val onEditCaption: ((ConversationMessage, String?) -> Unit)? = null,
    /** Event IDs saved for later here, which the sheet offers to remove; [onSave] saves (true) or removes one. */
    val saved: Set<String> = emptySet(),
    val onSave: ((ConversationMessage, Boolean) -> Unit)? = null,
)

/** The sheet's reaction row holds five, beside Add reaction, so each keeps a full touch target on the narrowest phones. */
private const val QUICK_REACTIONS = 5

private val textKinds = setOf(MessageKind.Text, MessageKind.Notice, MessageKind.Emote)

/** What a forward can copy: text, and any attachment, which goes as the same media. */
private val forwardKinds = textKinds + MessageKind.Attachment

/** The long-press sheet, the emoji picker it opens and the delete confirmation, one after another. */
@Composable
internal fun MessageActionsHost(message: ConversationMessage, actions: MessageActions, onOpenThread: ((String) -> Unit)?,
    onRetrySend: (ConversationMessage) -> Unit, onDeleteUnsent: (ConversationMessage) -> Unit, onDismiss: () -> Unit) {
    var step by remember(message.id) { mutableStateOf(Step.Sheet) }
    when (step) {
        Step.Sheet -> MessageSheet(message, actions, onOpenThread, onRetrySend, onDeleteUnsent, { step = it }, onDismiss)
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
        Step.Caption -> CaptionSheet(message, { caption -> actions.onEditCaption?.invoke(message, caption); onDismiss() }, onDismiss)
    }
}

private enum class Step { Sheet, Picker, ConfirmDelete, Caption }

/**
 * Slack's message sheet: the quick reactions across its top, where the thumb already is, over its actions. The actions
 * scroll inside the lower part of the screen, so the reactions never climb out of reach.
 */
@Composable
private fun MessageSheet(message: ConversationMessage, actions: MessageActions, onOpenThread: ((String) -> Unit)?,
    onRetrySend: (ConversationMessage) -> Unit, onDeleteUnsent: (ConversationMessage) -> Unit,
    onStep: (Step) -> Unit, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    val clipboard = LocalClipboard.current
    val scope = rememberCoroutineScope()
    val eventId = message.eventId.takeIf { message.sendState == MessageSendState.Sent && message.kind != MessageKind.Deleted }
    fun copy(text: String) = scope.launch {
        clipboard.setClipEntry(ClipEntry(ClipData.newPlainText(message.senderName, text)))
        onDismiss()
    }
    val react = actions.onReact.takeIf { eventId != null }
    BottomSheet(onDismiss, colors.overlay) {
        BoxWithConstraints(Modifier.semantics { paneTitle = "Message from ${message.senderName}" }) {
            val most = maxHeight * UiMetrics.MessageSheetShare
            Column {
                if (react != null) Row(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapMedium).padding(bottom = UiMetrics.GapSmall),
                    horizontalArrangement = Arrangement.SpaceEvenly) {
                    actions.quick.forEach { emoji ->
                        ReactionButton("React with $emoji", { react(message, emoji); onDismiss() }) {
                            Text(emoji, style = MaterialTheme.typography.headlineSmall)
                        }
                    }
                    ReactionButton("Add reaction", { onStep(Step.Picker) }) {
                        Icon(Icons.Outlined.AddReaction, null, Modifier.size(UiMetrics.SheetIcon), tint = colors.textSecondary)
                    }
                }
                Column(Modifier.heightIn(max = most).verticalScroll(rememberScrollState()).padding(bottom = UiMetrics.GapSmall)) {
                    MessageSheetItems(message, eventId, actions, onOpenThread, onRetrySend, onDeleteUnsent, ::copy, scope, onStep, onDismiss)
                }
            }
        }
    }
}

/** A round quick reaction, a full touch target wide, so a thumb can't miss it. */
@Composable
private fun ReactionButton(label: String, onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(Modifier.size(UiMetrics.Touch).clip(CircleShape).background(SlatrixTheme.colors.reaction).clickable(role = Role.Button, onClick = onClick)
        .semantics { contentDescription = label }, contentAlignment = Alignment.Center) { content() }
}

/** The actions in Slack's order: answering and keeping, then copying and marking, then changing your own. */
@Composable
private fun MessageSheetItems(message: ConversationMessage, eventId: String?, actions: MessageActions, onOpenThread: ((String) -> Unit)?,
    onRetrySend: (ConversationMessage) -> Unit, onDeleteUnsent: (ConversationMessage) -> Unit, copy: (String) -> Unit,
    scope: CoroutineScope, onStep: (Step) -> Unit, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    if (message.sendState == MessageSendState.Failed) {
        if (message.canRetry) MenuItem(Icons.Outlined.Refresh, "Retry") { onRetrySend(message); onDismiss() }
        MenuItem(Icons.Outlined.Delete, "Delete message", colors.destructive) { onDeleteUnsent(message); onDismiss() }
    }
    if (eventId == null) {
        if (message.kind in textKinds) MenuItem(Icons.Outlined.Title, "Copy text") { copy(message.body) }
        return
    }
    val quote = actions.onQuote
    val forward = actions.onForward?.takeIf { message.kind in forwardKinds }
    val save = actions.onSave
    if (onOpenThread != null) MenuItem(Icons.Outlined.ChatBubbleOutline, "Reply in thread") { onOpenThread(eventId); onDismiss() }
    if (quote != null) MenuItem(Icons.Outlined.FormatQuote, "Quote") { quote(message); onDismiss() }
    if (forward != null) MenuItem(SlackIcons.Forward, "Forward") { forward(message); onDismiss() }
    if (save != null) {
        val isSaved = eventId in actions.saved
        MenuItem(if (isSaved) SlackIcons.BookmarkFilled else SlackIcons.Bookmark, if (isSaved) "Remove from Later" else "Save for later") {
            save(message, !isSaved); onDismiss()
        }
    }
    val link = actions.link
    val markUnread = actions.onMarkUnread
    val pin = actions.onPin
    if (message.kind in textKinds) MenuItem(Icons.Outlined.Title, "Copy text") { copy(message.body) }
    if (link != null) MenuItem(Icons.Outlined.Link, "Copy link") { scope.launch { link(message)?.let { copy(it) } ?: onDismiss() } }
    if (markUnread != null) MenuItem(SlackIcons.MarkUnread, "Mark unread") { markUnread(); onDismiss() }
    if (pin != null) {
        val pinned = eventId in actions.pinned
        MenuItem(Icons.Outlined.PushPin, if (pinned) "Unpin from ${actions.place}" else "Pin to ${actions.place}") {
            pin(message, !pinned); onDismiss()
        }
    }
    if (actions.onEdit != null && message.editable) MenuItem(Icons.Outlined.Edit, "Edit message") { actions.onEdit.invoke(message); onDismiss() }
    // As on the Mac, an image's or a file's.
    if (message.own && actions.onEditCaption != null && message.attachment?.kind in setOf(MessageAttachment.Kind.Image, MessageAttachment.Kind.File)) {
        MenuItem(Icons.Outlined.Edit, "Edit caption") { onStep(Step.Caption) }
    }
    if (message.own && actions.onDelete != null) MenuItem(Icons.Outlined.Delete, "Delete message", colors.destructive) { onStep(Step.ConfirmDelete) }
}

/** The sheet's actions on an open conversation; reacting also moves the emoji up your recent list. */
@Composable
internal fun rememberMessageActions(conversation: MatrixConversation?, composer: MatrixComposer?, workspace: MatrixWorkspace?,
    room: RoomSummary): MessageActions {
    val recent = workspace?.emojiHistory?.state?.collectAsState()?.value.orEmpty()
    return remember(conversation, composer, workspace, recent, room.pinned, room.canPin, room.direct) {
        if (conversation == null) return@remember MessageActions()
        MessageActions(
            quick = EmojiRecents.quick(recent, QUICK_REACTIONS), recent = recent,
            onReact = { message, emoji -> conversation.react(message, emoji) { workspace?.emojiHistory?.use(emoji) } },
            link = conversation::link,
            onDelete = conversation::delete,
            onEditCaption = conversation::editCaption,
            onQuote = { message -> ComposerTarget.reply(message)?.let { composer?.reply(it) } },
            onEdit = { message -> ComposerTarget.edit(message)?.let { composer?.editMessage(it) } },
            pinned = room.pinned.toSet(),
            onPin = conversation::pin.takeIf { room.canPin },
            place = if (room.direct) "conversation" else "channel",
        )
    }
}
