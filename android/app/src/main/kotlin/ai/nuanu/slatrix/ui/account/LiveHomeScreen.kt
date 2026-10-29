package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.RoomListState
import ai.nuanu.slatrix.core.UnreadBadge
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable

@Composable
fun LiveHomeScreen(userId: String, state: RoomListState, onRoom: (String) -> Unit, onYou: () -> Unit, onRetry: () -> Unit) {
    state.rooms.forEach { room ->
        Text(room.name)
        (room.unread as? UnreadBadge.Count)?.let { Text(it.label) }
    }
}
