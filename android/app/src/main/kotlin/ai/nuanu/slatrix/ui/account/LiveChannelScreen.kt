package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.RoomSummary
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable

@Composable
fun LiveChannelScreen(room: RoomSummary, state: ConversationState, composer: ComposerState,
    onDraft: (String) -> Unit, onSend: () -> Unit, onBack: () -> Unit, onLoadOlder: () -> Unit, onRead: (String) -> Unit) {
    Text(room.name)
}
