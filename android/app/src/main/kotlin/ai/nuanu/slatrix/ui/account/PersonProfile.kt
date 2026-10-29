package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.MatrixPeople
import ai.nuanu.slatrix.core.Person
import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AlternateEmail
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/**
 * Slack's profile, pushed over what was open: the picture, the name, Message for someone else, and the Matrix ID under
 * Contact information. [opening] holds Message while it finds or makes the conversation; [error] says why it couldn't.
 */
@Composable
fun PersonProfileScreen(person: Person, own: Boolean, opening: Boolean, error: String?, onMessage: () -> Unit, onBack: () -> Unit) {
    val colors = SlatrixTheme.colors
    Box(Modifier.fillMaxSize()) {
        PushedPage("Profile", onBack) {
            item {
                Column(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
                    // Colored by the ID, so the tile keeps its color when the profile's name replaces the room's.
                    LiveAvatar(AvatarPlaceholder.initials(person.name), AvatarPlaceholder.colorIndex(person.id), UiMetrics.ProfilePhoto, person.avatarUrl)
                    Text(person.name, style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Black, color = colors.textPrimary)
                    if (!own) OutlinedButton(onMessage, Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch), enabled = !opening,
                        shape = MaterialTheme.shapes.small) {
                        // After a moment, a spinner takes the icon's place, so the label never moves.
                        var waited by remember { mutableStateOf(false) }
                        LaunchedEffect(opening) { waited = false; if (opening) { delay(UiMetrics.ProgressDelayMillis); waited = true } }
                        if (opening && waited) CircularProgressIndicator(Modifier.size(UiMetrics.Icon))
                        else Icon(SlackIcons.Messages, null, Modifier.size(UiMetrics.Icon))
                        Text("Message", Modifier.padding(start = UiMetrics.GapSmall), style = MaterialTheme.typography.bodyLarge,
                            fontWeight = FontWeight.Bold, color = colors.textPrimary)
                    }
                }
                HorizontalDivider(color = colors.border)
                Column(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
                    Text("Contact information", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold,
                        color = colors.textPrimary)
                    Row(horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(UiMetrics.ListAvatar).clip(MaterialTheme.shapes.large).background(colors.sunken),
                            contentAlignment = Alignment.Center) {
                            Icon(Icons.Outlined.AlternateEmail, null, Modifier.size(UiMetrics.Icon), tint = colors.textSecondary)
                        }
                        Column {
                            Text("Matrix ID", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Bold,
                                color = colors.textSecondary)
                            Text(person.id, style = MaterialTheme.typography.bodyLarge, color = colors.accent, maxLines = 1,
                                overflow = TextOverflow.MiddleEllipsis)
                        }
                    }
                }
            }
        }
        error?.let { message ->
            Snackbar(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(UiMetrics.GapLarge)
                .semantics { liveRegion = LiveRegionMode.Polite }) { Text(message) }
        }
    }
}

/**
 * The profile of [userId], shown at once with what is known of them, [known], and filled in from the server. Message
 * opens your direct message with them, made if there is none, in [onOpen].
 */
@Composable
fun LivePersonProfile(userId: String, known: String?, me: String, people: MatrixPeople?, rooms: Flow<RoomListState>?,
    onOpen: (RoomSummary) -> Unit, onBack: () -> Unit) {
    val person by produceState(Person(userId, known ?: userId), userId, people) {
        people?.profile(userId)?.let { value = it }
    }
    val scope = rememberCoroutineScope()
    var opening by remember(userId) { mutableStateOf(false) }
    var error by remember(userId) { mutableStateOf<String?>(null) }
    PersonProfileScreen(person, own = userId == me, opening, error, {
        if (people != null && rooms != null && !opening) {
            opening = true
            error = null
            scope.launch {
                val room = people.message(userId, rooms)
                opening = false
                if (room != null) onOpen(room) else error = "Couldn’t open the conversation."
            }
        }
    }, onBack)
    error?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); error = null } }
}
