package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.ConversationSearch
import ai.nuanu.slatrix.core.MessageSearchQuery
import ai.nuanu.slatrix.core.MessageSearchState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.SearchHit
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle

/**
 * Slack's Search tab: the field takes focus as the tab opens; typing lists matching channels and people, and searching
 * lists the messages the index matched. [rooms] are the conversations in scope, so hits elsewhere stay out.
 */
@Composable
fun SearchScreen(rooms: List<RoomSummary>, me: String, messages: MessageSearchState, onSearch: (MessageSearchQuery?) -> Unit,
    onMore: () -> Unit, onMessage: (SearchHit) -> Unit, onRoom: (String) -> Unit) {
    var text by rememberSaveable { mutableStateOf("") }
    var submitted by rememberSaveable { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    val focusManager = LocalFocusManager.current
    // Coming back to results leaves the keyboard down, so it doesn't cover them; after the process was gone, it asks again.
    LaunchedEffect(Unit) {
        if (!submitted) { focus.requestFocus(); keyboard?.show() }
        else if (messages.query == null) onSearch(MessageSearchQuery.parse(text, rooms, me))
    }
    val submit = {
        if (text.isNotBlank()) {
            onSearch(MessageSearchQuery.parse(text, rooms, me))
            submitted = true
            focusManager.clearFocus()
        }
    }
    Column(Modifier.fillMaxSize()) {
        SearchField(text, { value ->
            text = value
            if (submitted) { submitted = false; onSearch(null) }
        }, submit, Modifier.focusRequester(focus))
        when {
            submitted -> MessageResults(text.trim(), rooms, messages, onMore, onMessage)
            text.isNotBlank() -> Suggestions(text, rooms, submit, onRoom)
        }
    }
}

@Composable
private fun SearchField(text: String, onText: (String) -> Unit, onSubmit: () -> Unit, modifier: Modifier) {
    val colors = SlatrixTheme.colors
    BasicTextField(text, onText, modifier.fillMaxWidth().padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        singleLine = true, textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.textPrimary),
        cursorBrush = SolidColor(colors.accent),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search), keyboardActions = KeyboardActions(onSearch = { onSubmit() }),
        decorationBox = { field ->
            Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.SearchField).clip(MaterialTheme.shapes.large)
                .border(UiMetrics.Divider, colors.borderStrong, MaterialTheme.shapes.large).background(colors.canvas)
                .padding(start = UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Icon(SlackIcons.Search, null, Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
                Box(Modifier.weight(1f)) {
                    if (text.isEmpty()) Text("Search", style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary)
                    field()
                }
                if (text.isNotEmpty()) {
                    // As tall as the field, so the target is bigger than the glyph without growing the field.
                    Box(Modifier.size(UiMetrics.SearchField).clickable(role = Role.Button) { onText("") }
                        .semantics { contentDescription = "Clear" }, contentAlignment = Alignment.Center) {
                        Icon(SlackIcons.Close, null, Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
                    }
                }
            }
        })
}

@Composable
private fun Suggestions(text: String, rooms: List<RoomSummary>, onSubmit: () -> Unit, onRoom: (String) -> Unit) {
    val channels = remember(text, rooms) { ConversationSearch.results(rooms.filterNot { it.direct }, text).take(SuggestionCount) }
    val people = remember(text, rooms) { ConversationSearch.results(rooms.filter { it.direct }, text).take(SuggestionCount) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = UiMetrics.GapSmall)) {
        item {
            SearchRow(onSubmit) {
                Icon(SlackIcons.Search, null, Modifier.size(UiMetrics.Icon))
                Spacer(Modifier.width(UiMetrics.GapLarge))
                Text("Search for “${text.trim()}”", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (channels.isNotEmpty()) {
            item { SearchSection("Channels") }
            items(channels, key = { it.id }) { room ->
                SearchRow({ onRoom(room.id) }) {
                    Icon(if (room.isPrivate) SlackIcons.Lock else SlackIcons.Hash, if (room.isPrivate) "Private channel" else null,
                        Modifier.size(UiMetrics.Icon))
                    Spacer(Modifier.width(UiMetrics.GapLarge))
                    RowTitle(room.name)
                }
            }
        }
        if (people.isNotEmpty()) {
            item { SearchSection("People") }
            items(people, key = { it.id }) { room ->
                SearchRow({ onRoom(room.id) }) {
                    LiveAvatar(room.initials, room.colorIndex, UiMetrics.CompactAvatar, room.avatarUrl)
                    Spacer(Modifier.width(UiMetrics.GapMedium))
                    RowTitle(room.name)
                }
            }
        }
    }
}

@Composable
private fun MessageResults(text: String, rooms: List<RoomSummary>, messages: MessageSearchState, onMore: () -> Unit,
    onMessage: (SearchHit) -> Unit) {
    val hits = remember(messages.hits, rooms) { messages.hits.filter { hit -> rooms.any { it.id == hit.roomId } } }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = UiMetrics.GapSmall)) {
        items(hits, key = { it.roomId + it.eventId }) { hit ->
            MessageHit(hit, rooms.firstOrNull { it.id == hit.roomId }, messages.query) { onMessage(hit) }
        }
        when {
            messages.error != null -> item { SearchNote(messages.error) }
            messages.loading -> item { ConnectionIndicator(true, null) }
            // Asks for the next page as the end comes into view; a page with no hits here asks for the one after.
            !messages.endReached -> item { LaunchedEffect(messages.hits.size) { onMore() } }
            hits.isEmpty() -> item { SearchNote("No results for “$text”") }
        }
    }
}

/** A matched message as Slack lists it: where it was, who wrote it and when, then the message with its matches marked. */
@Composable
private fun MessageHit(hit: SearchHit, room: RoomSummary?, query: MessageSearchQuery?, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    val body = remember(hit.body, query, colors) {
        buildAnnotatedString {
            var at = 0
            for (range in query?.highlights(hit.body).orEmpty()) {
                append(hit.body.substring(at, range.first))
                withStyle(SpanStyle(fontWeight = FontWeight.Bold, background = colors.highlight)) { append(hit.body.substring(range)) }
                at = range.last + 1
            }
            append(hit.body.substring(at))
        }
    }
    Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        LiveAvatar(AvatarPlaceholder.initials(hit.senderName), AvatarPlaceholder.colorIndex(hit.senderName), UiMetrics.ListAvatar,
            hit.senderAvatarUrl)
        Column(Modifier.weight(1f)) {
            Text(room?.let { if (it.direct) it.name else "#${it.name}" }.orEmpty(), style = MaterialTheme.typography.bodySmall,
                color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapSmall)) {
                Text(hit.senderName, Modifier.weight(1f, fill = false), style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(latestTime(hit.timestamp), style = MaterialTheme.typography.bodySmall, color = colors.textBody)
            }
            Text(body, style = MaterialTheme.typography.bodyLarge, color = colors.textBody, maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun SearchRow(onClick: () -> Unit, content: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ListRow).clickable(role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically) {
        content()
    }
}

@Composable
private fun RowScope.RowTitle(name: String) {
    Text(name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textBody,
        maxLines = 1, overflow = TextOverflow.Ellipsis)
}

@Composable
private fun SearchSection(label: String) {
    Text(label, Modifier.padding(start = UiMetrics.GapLarge, end = UiMetrics.GapLarge, top = UiMetrics.GapMedium, bottom = UiMetrics.GapTiny),
        style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = SlatrixTheme.colors.textSecondary)
}

@Composable
private fun SearchNote(text: String) {
    Text(text, Modifier.padding(UiMetrics.GapLarge), style = MaterialTheme.typography.bodyLarge, color = SlatrixTheme.colors.textSecondary)
}

private const val SuggestionCount = 5
