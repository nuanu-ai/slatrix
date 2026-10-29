package ai.nuanu.slatrix.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.matrix.rustcomponents.sdk.Client

data class RoomSummary(
    val id: String,
    val name: String,
    val direct: Boolean,
    val topic: String,
    val unread: UnreadBadge,
    val initials: String,
    val colorIndex: Int,
)

data class RoomListState(
    val rooms: List<RoomSummary> = emptyList(),
    val loading: Boolean = true,
    val error: String? = null,
)

class MatrixRooms(scope: CoroutineScope, client: Client) {
    val state: StateFlow<RoomListState> = MutableStateFlow(RoomListState())
    fun retry() = Unit
    suspend fun close() = Unit
}
