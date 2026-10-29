package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ComposerTarget
import ai.nuanu.slatrix.core.MentionCandidate
import ai.nuanu.slatrix.core.MentionPeople
import ai.nuanu.slatrix.core.MentionSearch
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material.icons.outlined.AlternateEmail
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties

/** What the composer can do beyond typing and sending; a mention needs [people], an attachment [onAttach]. */
data class ComposerActions(
    val onCancelTarget: () -> Unit = {},
    val people: MentionPeople? = null,
    val onNeedPeople: () -> Unit = {},
    val onMention: (start: Int, end: Int, candidate: MentionCandidate) -> Unit = { _, _, _ -> },
)

/**
 * Slack Android's composer: the field, then a toolbar of what works here (emoji and @) with send at its end. The
 * thread screen uses it too; [recentSenders], latest first, rank who an @ suggests.
 */
@Composable
fun MessageComposer(room: RoomSummary, composer: ComposerState, onDraft: (String) -> Unit, onSend: () -> Unit,
    actions: ComposerActions, recentSenders: List<String> = emptyList()) {
    val colors = SlatrixTheme.colors
    val description = if (room.direct) "Message ${room.name}" else "Message #${room.name}"
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
    var height by remember { mutableIntStateOf(0) }
    Column(Modifier.fillMaxWidth().onSizeChanged { height = it.height }) {
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
        HorizontalDivider(color = colors.border)
        composer.target?.let { TargetBar(it, actions.onCancelTarget) }
        BasicTextField(shown, { next ->
            field = next
            pending = null
            val changed = next.text != lastText
            lastText = next.text
            if (changed) onDraft(next.text)
        }, enabled = !composer.loading,
            modifier = Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).padding(horizontal = UiMetrics.GapMedium)
                .semantics { contentDescription = description },
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.textBody),
            cursorBrush = SolidColor(colors.accent), maxLines = 5,
            decorationBox = { inner ->
                Box(Modifier.padding(vertical = UiMetrics.GapMedium), contentAlignment = Alignment.CenterStart) {
                    if (composer.text.isEmpty()) Text(description, style = MaterialTheme.typography.bodyLarge,
                        color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    inner()
                }
            })
        Row(Modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { picking = true }, enabled = !composer.loading) {
                Icon(Icons.Outlined.EmojiEmotions, "Emoji", tint = colors.textSecondary)
            }
            IconButton(onClick = {
                val selection = shown.selection
                val before = shown.text.substring(0, selection.min)
                replace(selection.min, selection.max, if (before.isEmpty() || before.last().isWhitespace()) "@" else " @")
            }, enabled = !composer.loading) {
                Icon(Icons.Outlined.AlternateEmail, "Mention someone", tint = colors.textSecondary)
            }
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onSend, enabled = !composer.loading && !composer.sending && composer.text.isNotBlank()) {
                Icon(if (editing) Icons.Outlined.Check else Icons.AutoMirrored.Outlined.Send,
                    if (editing) "Save changes" else "Send message",
                    tint = if (composer.text.isNotBlank()) colors.accent else colors.textTertiary)
            }
        }
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
                                UiMetrics.CompactAvatar)
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
