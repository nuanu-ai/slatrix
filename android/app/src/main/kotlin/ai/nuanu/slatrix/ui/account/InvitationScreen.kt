package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.Invitation
import ai.nuanu.slatrix.core.Invitations
import ai.nuanu.slatrix.core.MatrixRooms
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.ui.designsystem.SlackIcons
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.MailOutline
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * An invitation, opened from Home as the Mac shows one: what you're invited to and by whom, with Decline and Join.
 * [responding] holds both buttons while one is at work.
 */
@Composable
fun InvitationScreen(invitation: Invitation, responding: Boolean, error: String?, onJoin: () -> Unit, onDecline: () -> Unit,
    onBack: () -> Unit) {
    val colors = SlatrixTheme.colors
    val title = if (invitation.direct || invitation.space) invitation.name else "#${invitation.name}"
    Box(Modifier.fillMaxSize()) {
        PushedPage(title, onBack) {
            item {
                Column(Modifier.fillMaxWidth().padding(UiMetrics.GapSection), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
                    if (invitation.direct || invitation.space) LiveAvatar(invitation.initials, invitation.colorIndex, UiMetrics.ProfileAvatar)
                    else Icon(SlackIcons.Hash, null, Modifier.size(UiMetrics.ProfileAvatar))
                    Text("You’re invited to $title", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                        color = colors.textPrimary, textAlign = TextAlign.Center)
                    invitation.inviter?.let {
                        Text("$it invited you.", style = MaterialTheme.typography.bodyLarge, color = colors.textSecondary,
                            textAlign = TextAlign.Center)
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                        OutlinedButton(onDecline, Modifier.weight(1f).heightIn(min = UiMetrics.Touch), enabled = !responding,
                            shape = MaterialTheme.shapes.small) { Text("Decline") }
                        Button(onJoin, Modifier.weight(1f).heightIn(min = UiMetrics.Touch), enabled = !responding,
                            shape = MaterialTheme.shapes.small) { Text(if (invitation.space) "Join workspace" else "Join") }
                    }
                    // Its place is kept, so the buttons never move when it shows.
                    Box(Modifier.size(UiMetrics.Icon)) {
                        var waited by remember { mutableStateOf(false) }
                        LaunchedEffect(responding) { waited = false; if (responding) { delay(UiMetrics.ProgressDelayMillis); waited = true } }
                        if (responding && waited) CircularProgressIndicator(Modifier.size(UiMetrics.Icon))
                    }
                }
            }
        }
        error?.let {
            Snackbar(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(UiMetrics.GapLarge)
                .semantics { liveRegion = LiveRegionMode.Polite }) { Text(it) }
        }
    }
}

/**
 * The invitation [id], live: Join opens what it was to, once sync lists it (a workspace becomes the open one), and
 * Decline goes back. One that goes away meanwhile, answered on another device, closes.
 */
@Composable
fun LiveInvitation(id: String, rooms: MatrixRooms?, onJoined: (RoomSummary) -> Unit, onWorkspace: (String) -> Unit,
    onNotice: (String) -> Unit, onBack: () -> Unit) {
    if (rooms == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val state = rooms.state.collectAsState().value
    val scope = rememberCoroutineScope()
    var responding by remember(id) { mutableStateOf(false) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    // Kept once seen, so the page stays put while a Join it started takes the invitation off the list.
    val seen = remember(id) { arrayOfNulls<Invitation>(1) }
    state.invitations.firstOrNull { it.id == id }?.let { seen[0] = it }
    val gone = !state.loading && state.invitations.none { it.id == id } && !responding
    val invitation = seen[0]
    // Until the list loads, as after the app was away, the page waits blank rather than close.
    if (invitation == null && state.loading) {
        BackHandler(onBack = onBack)
        return
    }
    if (invitation == null || gone) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val client = rooms.client
    fun answer(accept: Boolean) {
        // One answer at a time: a second tap before the buttons disable must not send another.
        if (responding) return
        responding = true
        error = null
        scope.launch {
            if (!Invitations.respond(client, id, accept)) {
                responding = false
                error = if (accept) "Couldn’t join ${invitation.name}." else "Couldn’t decline the invitation."
                return@launch
            }
            if (!accept) return@launch onBack()
            val arrived = withTimeoutOrNull(30_000) {
                rooms.state.first { list -> list.spaces.any { it.id == id } || list.rooms.any { it.id == id } }
            }
            when {
                arrived == null -> { onNotice("Joined. It’ll show up in a moment."); onBack() }
                invitation.space -> onWorkspace(id)
                else -> arrived.rooms.firstOrNull { it.id == id }?.let(onJoined) ?: onBack()
            }
        }
    }
    InvitationScreen(invitation, responding, error, { answer(true) }, { answer(false) }, onBack)
    error?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); error = null } }
}

/** Home's Invitations header: Slack's section look, with nothing to collapse, since every invitation stays in view. */
@Composable
internal fun InvitationsHeader() {
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.ListRow).padding(horizontal = UiMetrics.GapLarge),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapLarge)) {
        Icon(Icons.Outlined.MailOutline, null, Modifier.size(UiMetrics.Icon))
        Text("Invitations", style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}

/** An invitation on Home, bold as an unread conversation is; a tap opens it to accept or decline. */
@Composable
internal fun InvitationRow(invitation: Invitation, onOpen: (String) -> Unit) {
    val colors = SlatrixTheme.colors
    Row(Modifier.fillMaxWidth().heightIn(min = UiMetrics.Touch).clickable(role = Role.Button) { onOpen(invitation.id) }
        .semantics { stateDescription = "Invitation" }.padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapTiny),
        verticalAlignment = Alignment.CenterVertically) {
        // As Home's rows do, so every name starts at the same place.
        if (invitation.direct || invitation.space) {
            LiveAvatar(invitation.initials, invitation.colorIndex, UiMetrics.CompactAvatar)
            Spacer(Modifier.width(UiMetrics.GapMedium))
        } else {
            Icon(SlackIcons.Hash, null, Modifier.size(UiMetrics.Icon), tint = colors.textPrimary)
            Spacer(Modifier.width(UiMetrics.GapLarge))
        }
        Text(invitation.name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, color = colors.textPrimary,
            fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
