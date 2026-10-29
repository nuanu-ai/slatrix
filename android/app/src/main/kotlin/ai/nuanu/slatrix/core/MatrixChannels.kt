package ai.nuanu.slatrix.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.matrix.rustcomponents.sdk.Client

data class DirectoryChannel(val id: String, val name: String, val topic: String?, val members: Long, val canJoin: Boolean,
    val rule: String = "", val via: List<String> = emptyList())

data class ChannelDirectoryState(
    val channels: List<DirectoryChannel> = emptyList(),
    val loading: Boolean = false,
    val more: Boolean = false,
    val error: String? = null,
)

class ChannelDirectory(private val scope: CoroutineScope, private val client: Client, private val spaceId: String?) {
    val state: StateFlow<ChannelDirectoryState> = MutableStateFlow(ChannelDirectoryState(loading = true))
    fun search(query: String) {}
    fun loadMore() {}
    fun close() {}
}

object Channels {
    suspend fun join(client: Client, channel: DirectoryChannel, rooms: Flow<RoomListState>): RoomSummary? = null
    suspend fun create(client: Client, name: String, topic: String, spaceId: String?, rooms: Flow<RoomListState>): ChannelCreation =
        ChannelCreation()
}

data class ChannelCreation(val room: RoomSummary? = null, val error: String? = null)
