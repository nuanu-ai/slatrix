package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.MessageSearchQuery
import ai.nuanu.slatrix.core.MessageSearchState
import ai.nuanu.slatrix.core.RoomSummary
import androidx.compose.runtime.Composable

@Composable
fun SearchScreen(rooms: List<RoomSummary>, me: String, messages: MessageSearchState, onSearch: (MessageSearchQuery?) -> Unit,
    onMore: () -> Unit, onRoom: (String) -> Unit) = Unit
