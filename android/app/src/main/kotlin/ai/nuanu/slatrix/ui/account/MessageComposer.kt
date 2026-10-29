package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ComposerStyle
import ai.nuanu.slatrix.core.ComposerStyles
import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.MentionCandidate
import ai.nuanu.slatrix.core.MentionPeople
import ai.nuanu.slatrix.core.MentionSearch
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.AlternateEmail
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.EmojiEmotions
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties

/** What the composer can do beyond typing and sending; a mention needs [people], an attachment [onAttach], "Aa" [onFormat]. */
data class ComposerActions(
    val onCancelTarget: () -> Unit = {},
    val people: MentionPeople? = null,
    val onNeedPeople: () -> Unit = {},
    val onMention: (start: Int, end: Int, candidate: MentionCandidate) -> Unit = { _, _, _ -> },
    val onAttach: ((List<Uri>) -> Unit)? = null,
    val onFormat: ((start: Int, end: Int, kind: ComposerStyle.Kind, href: String?) -> Unit)? = null,
)

/**
 * Slack Android's composer: the field, then a toolbar of what works here (emoji and @) with send at its end. The
 * thread screen uses it too; [recentSenders], latest first, rank who an @ suggests.
 */
@Composable
fun MessageComposer(placeholder: String, composer: ComposerState, onDraft: (String) -> Unit, onSend: () -> Unit,
    actions: ComposerActions, recentSenders: List<String> = emptyList()) {
    val colors = SlatrixTheme.colors
    val editing = composer.target is ComposerTarget.Edit
    // As BasicTextField(String) does: the text always comes from the composer, the caret from here.
    var field by remember { mutableStateOf(TextFieldValue(composer.text)) }
    var lastText by remember { mutableStateOf(composer.text) }
    // A change made here, waiting for the composer's text to catch up before its caret applies.
    var pending by remember { mutableStateOf<TextFieldValue?>(null) }
    val shown = field.copy(text = composer.text)
    SideEffect {
        val waiting = pending
        if (waiting != null) {
            if (waiting.text == composer.text) { field = waiting; pending = null }
        } else if (shown.selection != field.selection || shown.composition != field.composition) field = shown
    }
    fun replace(start: Int, end: Int, insert: String) {
        val text = shown.text.replaceRange(start, end, insert)
        pending = TextFieldValue(text, TextRange(start + insert.length))
        lastText = text
        onDraft(text)
    }
    val caret = shown.selection.takeIf { it.collapsed }?.start
    val people = actions.people
    val suggestions = remember(shown.text, caret, people, recentSenders) {
        if (caret == null || people == null) null
        else MentionSearch.suggestions(shown.text.substring(0, caret), people.members, recentSenders, people.offersRoom)
    }
    val asking = caret != null && shown.text.substring(0, caret).let { before ->
        val at = before.lastIndexOf('@')
        at >= 0 && (at == 0 || before[at - 1].isWhitespace())
    }
    LaunchedEffect(asking) { if (asking) actions.onNeedPeople() }
    var picking by remember { mutableStateOf(false) }
    if (picking) EmojiPickerSheet(emptyList(), { emoji ->
        picking = false
        val selection = shown.selection
        replace(selection.min, selection.max, emoji)
    }) { picking = false }
    var formatting by remember { mutableStateOf(false) }
    // The selection a link goes on, while its sheet asks for the address; at the caret, the link there.
    var linking by remember { mutableStateOf<TextRange?>(null) }
    val focus = LocalFocusManager.current
    val onFormat = actions.onFormat
    val range = linking
    if (range != null && onFormat != null) {
        val link = composer.styles.firstOrNull { it.kind == ComposerStyle.Kind.Link && it.start <= range.max && range.min <= it.end &&
            (!range.collapsed || it.start < range.min && range.min < it.end) }
        val target = if (range.collapsed && link != null) TextRange(link.start, link.end) else range
        LinkSheet(target.collapsed, link?.href, { label, href ->
            linking = null
            if (label != null) replace(target.min, target.max, label)
            onFormat(target.min, if (label != null) target.min + label.length else target.max, ComposerStyle.Kind.Link, href)
        }) { linking = null }
    }
    var height by remember { mutableIntStateOf(0) }
    // Slack's composer is a panel with rounded top corners over the conversation.
    Column(Modifier.fillMaxWidth().onSizeChanged { height = it.height }
        .border(UiMetrics.Divider, colors.border, SlatrixTheme.topPanelShape).background(colors.canvas, SlatrixTheme.topPanelShape)
        .padding(top = UiMetrics.GapTiny)) {
        if (suggestions != null && !editing) Popup(Alignment.BottomStart, IntOffset(0, -height),
            properties = PopupProperties(focusable = false)) {
            MentionList(suggestions.candidates) { candidate ->
                val label = when (candidate) {
                    is MentionCandidate.Member -> "@${candidate.person.name} "
                    MentionCandidate.Room -> "@room "
                }
                pending = TextFieldValue(shown.text.replaceRange(suggestions.start, suggestions.end, label),
                    TextRange(suggestions.start + label.length))
                lastText = pending!!.text
                actions.onMention(suggestions.start, suggestions.end, candidate)
            }
        }
        composer.target?.let { TargetBar(it, actions.onCancelTarget) }
        val attach = actions.onAttach?.takeIf { !editing }
        ReceiveKeyboardMedia(attach) {
            BasicTextField(shown, { next ->
                val left = ComposerStyles.blockLeft(composer.styles, composer.typing, shown.text, next.text, shown.selection.min)
                    .takeIf { shown.selection.collapsed && onFormat != null }
                if (left != null) {
                    onFormat?.invoke(shown.selection.min, shown.selection.min, left, null)
                    return@BasicTextField
                }
                field = next
                pending = null
                val changed = next.text != lastText
                lastText = next.text
                if (changed) onDraft(next.text)
            }, enabled = !composer.loading,
                modifier = Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapMedium)
                    .semantics { contentDescription = placeholder },
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.textBody),
                visualTransformation = remember(composer.styles, composer.mentions, composer.typing, colors) {
                    ComposerVisual(composer.styles, composer.mentions, composer.typing?.takeIf { it.position == 0 }?.kinds?.firstOrNull { it.block }, colors)
                },
                cursorBrush = SolidColor(colors.accent), maxLines = 5,
                decorationBox = { inner ->
                    Box(Modifier.padding(vertical = UiMetrics.GapMedium), contentAlignment = Alignment.CenterStart) {
                        if (composer.text.isEmpty()) Text(placeholder, style = MaterialTheme.typography.bodyLarge,
                            color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        inner()
                    }
                })
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically) {
            if (!formatting) attach?.let { AttachButton(it) }
            if (onFormat != null) FormattingToggle(formatting, !composer.loading) { formatting = !formatting }
            if (formatting && onFormat != null) {
                val selection = shown.selection
                val caret = selection.max
                val active = ComposerStyles.typing(composer.styles, composer.typing.takeIf { selection.collapsed }, composer.text,
                    caret.coerceAtMost(composer.text.length))
                FormattingBar(active, !composer.loading, { onFormat(selection.min, selection.max, it, null) }) {
                    // The sheet's field takes the keyboard.
                    focus.clearFocus()
                    linking = selection
                }
            } else {
                IconButton(onClick = { picking = true }, enabled = !composer.loading) {
                    Icon(Icons.Outlined.EmojiEmotions, "Emoji", tint = colors.textPrimary)
                }
                IconButton(onClick = {
                    val selection = shown.selection
                    val before = shown.text.substring(0, selection.min)
                    replace(selection.min, selection.max, if (before.isEmpty() || before.last().isWhitespace()) "@" else " @")
                }, enabled = !composer.loading) {
                    Icon(Icons.Outlined.AlternateEmail, "Mention someone", tint = colors.textPrimary)
                }
                Spacer(Modifier.weight(1f))
            }
            IconButton(onClick = onSend, enabled = !composer.loading && !composer.sending && composer.text.isNotBlank()) {
                Icon(if (editing) Icons.Outlined.Check else Icons.AutoMirrored.Filled.Send,
                    if (editing) "Save changes" else "Send message",
                    tint = if (composer.text.isNotBlank()) colors.accent else colors.textTertiary)
            }
        }
    }
}

/** Slack's "+": a circle that offers photos and videos, or any file, from the system pickers. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AttachButton(onAttach: (List<Uri>) -> Unit) {
    val colors = SlatrixTheme.colors
    var choosing by remember { mutableStateOf(false) }
    val media = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { if (it.isNotEmpty()) onAttach(it) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { if (it.isNotEmpty()) onAttach(it) }
    val camera = rememberCamera { onAttach(listOf(it)) }
    IconButton(onClick = { choosing = true }, colors = IconButtonDefaults.iconButtonColors(containerColor = colors.raised)) {
        Icon(Icons.Outlined.Add, "Attachments", tint = colors.textPrimary)
    }
    if (choosing) ModalBottomSheet(onDismissRequest = { choosing = false }, shape = SlatrixTheme.topPanelShape,
        containerColor = colors.canvas) {
        Column(Modifier.fillMaxWidth().padding(bottom = UiMetrics.GapLarge)) {
            AttachChoice(Icons.Outlined.PhotoLibrary, "Photos & videos") {
                choosing = false
                media.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo))
            }
            camera?.let { AttachChoice(Icons.Outlined.PhotoCamera, "Camera") { choosing = false; it() } }
            AttachChoice(Icons.Outlined.Description, "Files") { choosing = false; files.launch(arrayOf("*/*")) }
        }
    }
}

@Composable
private fun AttachChoice(icon: ImageVector, label: String, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(onClick = onClick).padding(horizontal = UiMetrics.GapLarge),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(UiMetrics.SheetIcon), tint = colors.textPrimary)
        Text(label, style = MaterialTheme.typography.bodyLarge, color = colors.textPrimary)
    }
}

/** Slack's @ suggestions, over the conversation above the composer. */
@Composable
private fun MentionList(candidates: List<MentionCandidate>, onPick: (MentionCandidate) -> Unit) {
    val colors = SlatrixTheme.colors
    Column(Modifier.fillMaxWidth().background(colors.canvas)) {
        HorizontalDivider(color = colors.border)
        LazyColumn(Modifier.heightIn(max = UiMetrics.MentionListHeight)) {
            items(candidates, key = { (it as? MentionCandidate.Member)?.person?.id ?: "@room" }) { candidate ->
                Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable { onPick(candidate) }
                    .padding(horizontal = UiMetrics.GapLarge),
                    horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically) {
                    when (candidate) {
                        is MentionCandidate.Member -> {
                            LiveAvatar(AvatarPlaceholder.initials(candidate.person.name), AvatarPlaceholder.colorIndex(candidate.person.name),
                                UiMetrics.CompactAvatar, candidate.person.avatarUrl)
                            Text(candidate.person.name, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodyLarge,
                                fontWeight = FontWeight.Bold, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(candidate.person.id.removePrefix("@").substringBefore(':'), style = MaterialTheme.typography.bodyMedium,
                                color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        MentionCandidate.Room -> {
                            Icon(Icons.Outlined.AlternateEmail, null, Modifier.size(UiMetrics.CompactAvatar), tint = colors.textSecondary)
                            Text("@room", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold, color = colors.textPrimary)
                            Text("Notify everyone in this conversation", style = MaterialTheme.typography.bodyMedium,
                                color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
            }
        }
    }
}

/** The bar over the field while a send quotes a message or replaces your own, as on the Mac. */
@Composable
private fun TargetBar(target: ComposerTarget, onCancel: () -> Unit) {
    val colors = SlatrixTheme.colors
    val reply = target as? ComposerTarget.Reply
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min).padding(start = UiMetrics.GapLarge, top = UiMetrics.GapSmall),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(UiMetrics.QuoteBar).fillMaxHeight().background(colors.accent, MaterialTheme.shapes.small))
        Column(Modifier.weight(1f)) {
            Text(if (reply != null) "Replying to ${reply.senderName}" else "Editing message",
                style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = colors.textPrimary,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (reply != null) Text(reply.body, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        IconButton(onClick = onCancel) {
            Icon(Icons.Outlined.Close, if (reply != null) "Cancel reply" else "Cancel editing", Modifier.size(UiMetrics.Icon),
                tint = colors.textSecondary)
        }
    }
}
