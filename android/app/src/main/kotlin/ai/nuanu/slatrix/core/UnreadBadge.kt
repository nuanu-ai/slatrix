package ai.nuanu.slatrix.core

data class RoomUnread(
    val direct: Boolean = false,
    val muted: Boolean = false,
    val markedUnread: Boolean = false,
    val messages: Long = 0,
    val notifications: Long = 0,
    val mentions: Long = 0,
    val membership: String = "join",
    val space: Boolean = false,
)

sealed interface UnreadBadge {
    data object None : UnreadBadge
    data object Bold : UnreadBadge
    data class Count(val label: String) : UnreadBadge

    companion object {
        fun forRoom(room: RoomUnread): UnreadBadge {
            val count = count(room)
            return when {
                count > 0 -> Count(label(count))
                room.markedUnread || (!room.muted && (room.messages > 0 || room.notifications > 0)) -> Bold
                else -> None
            }
        }

        fun combined(rooms: List<RoomUnread>): UnreadBadge {
            val joined = rooms.filter { it.membership == "join" && !it.space }
            val total = joined.sumOf(::count)
            return when {
                total > 0 -> Count(label(total))
                joined.any { forRoom(it) != None } -> Bold
                else -> None
            }
        }

        private fun count(room: RoomUnread): Long =
            if (room.direct && !room.muted) maxOf(room.mentions, room.messages, room.notifications) else room.mentions

        private fun label(count: Long): String = if (count > 99) "99+" else count.toString()
    }
}
