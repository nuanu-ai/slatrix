package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.MatrixPeople
import ai.nuanu.slatrix.core.MatrixRooms
import ai.nuanu.slatrix.core.PeopleSearchState
import ai.nuanu.slatrix.core.Person
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Slack's New message: a To field that finds people in the server's directory, by name or full Matrix ID, over your
 * direct messages while it's empty. Picking someone opens your direct message with them, made if there is none.
 */
@Composable
fun NewMessageScreen(state: PeopleSearchState, recent: List<RoomSummary>, opening: String?, error: String?, onQuery: (String) -> Unit,
    onPerson: (Person) -> Unit, onRoom: (String) -> Unit, onBack: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) {
        focus.requestFocus()
        // After the page was recreated, such as on rotation, the query it still shows asks again.
        if (query.isNotBlank()) onQuery(query)
    }
    Box(Modifier.fillMaxSize()) {
        PushedPage("New message", onBack) {
            item { SearchField(query, { query = it; onQuery(it) }, { onQuery(query) }, Modifier.focusRequester(focus), "To: a name or Matrix ID") }
            if (query.isBlank()) {
                if (recent.isNotEmpty()) item { Section("Direct messages") }
                items(recent, key = { it.id }) { room ->
                    PersonRow(room.initials, room.colorIndex, room.avatarUrl, room.name, null, false, opening == null) { onRoom(room.id) }
                }
            } else {
                items(state.people, key = { it.id }) { person ->
                    PersonRow(AvatarPlaceholder.initials(person.name), AvatarPlaceholder.colorIndex(person.id), person.avatarUrl, person.name,
                        person.id.takeIf { it != person.name }, opening == person.id, opening == null) { onPerson(person) }
                }
                when {
                    state.error != null -> item { Section(state.error) }
                    state.loading && state.people.isEmpty() -> item { ConnectionIndicator(true, null) }
                    !state.loading && state.people.isEmpty() -> item { Section("No one found. A full ID looks like @name:example.org.") }
                }
            }
        }
        error?.let {
            Snackbar(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(UiMetrics.GapLarge)
                .semantics { liveRegion = LiveRegionMode.Polite }) { Text(it) }
        }
    }
}

@Composable
private fun PersonRow(initials: String, colorIndex: Int, url: String?, name: String, id: String?, opening: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.WorkspaceRow).clickable(enabled, role = Role.Button, onClick = onClick)
        .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapTiny), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
        LiveAvatar(initials, colorIndex, UiMetrics.ListAvatar, url)
        Column(Modifier.weight(1f)) {
            Text(name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold, color = colors.textPrimary,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            id?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1, overflow = TextOverflow.MiddleEllipsis) }
        }
        // Its place is kept, so the name never moves when the spinner shows.
        Box(Modifier.widthIn(min = UiMetrics.Icon), contentAlignment = Alignment.Center) { if (opening) DelayedSpinner() }
    }
}

@Composable
private fun Section(text: String) {
    Text(text, Modifier.padding(start = UiMetrics.GapLarge, end = UiMetrics.GapLarge, top = UiMetrics.GapMedium, bottom = UiMetrics.GapTiny),
        style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, color = SlatrixTheme.colors.textSecondary)
}

/** New message, live: the directory's answers as you type, and the conversation once picked. */
@Composable
fun LiveNewMessage(me: String, people: MatrixPeople?, rooms: MatrixRooms?, onOpen: (RoomSummary) -> Unit, onBack: () -> Unit) {
    // You can't message yourself, so the directory's answer leaves you out.
    val state = (people?.results?.collectAsState()?.value ?: PeopleSearchState()).let { it.copy(people = it.people.filter { person -> person.id != me }) }
    val known = rooms?.state?.collectAsState()?.value?.rooms.orEmpty()
    val recent = remember(known) { known.filter { it.direct } }
    val scope = rememberCoroutineScope()
    var opening by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    // Search shares the answers, so they go with the page.
    DisposableEffect(people) { onDispose { people?.search("") } }
    NewMessageScreen(state, recent, opening, error, { people?.search(it) }, { person ->
        if (people == null || rooms == null || opening != null) return@NewMessageScreen
        opening = person.id
        error = null
        scope.launch {
            val room = people.message(person.id, rooms.state)
            opening = null
            if (room != null) onOpen(room) else error = "Couldn’t open the conversation."
        }
    }, { id -> known.firstOrNull { it.id == id }?.let(onOpen) }, onBack)
    error?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); error = null } }
}
