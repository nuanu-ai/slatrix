package ai.nuanu.slatrix.push

import ai.nuanu.slatrix.core.RoomSummary

data class NotificationTarget(val userId: String, val roomId: String, val threadRoot: String? = null) {
    fun roomFor(currentUserId: String, rooms: List<RoomSummary>): RoomSummary? =
        if (currentUserId != userId) null else rooms.firstOrNull { it.id == roomId }
}
