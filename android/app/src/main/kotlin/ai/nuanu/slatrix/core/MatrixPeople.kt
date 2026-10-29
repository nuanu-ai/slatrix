package ai.nuanu.slatrix.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.MembershipState

/** Someone on the server: their Matrix ID, the name to show and their picture. */
data class Person(val id: String, val name: String, val avatarUrl: String? = null)

object DirectMessages {
    fun reusable(members: List<Pair<String, MembershipState>>, me: String, target: String): Boolean = false
}

class MatrixPeople(private val scope: CoroutineScope, private val client: Client) {
    suspend fun profile(userId: String): Person? = null
    suspend fun directRoom(userId: String): String = ""
    suspend fun message(userId: String, rooms: Flow<RoomListState>): RoomSummary? = null
    suspend fun counterpart(roomId: String): Person? = null
    fun close() {}
}
