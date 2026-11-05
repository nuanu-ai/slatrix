package ai.nuanu.slatrix.core

/**
 * Activity's red count, as `spec/activity-badge.json` has it: unread mentions, thread replies Activity lists that you
 * haven't opened, and invitations. Direct messages and channels keep their own badges, so their messages count only as
 * mentions.
 */
object ActivityBadge {
    fun count(rooms: List<RoomUnread>, items: List<ActivityItem>): Int {
        val mentions = rooms.sumOf {
            when (it.membership) {
                "invite" -> 1
                "leave" -> 0
                else -> it.mentions.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            }
        }
        // A reply that mentions you is listed as a mention, and counts through its room's mentions.
        return mentions + items.count { it.kind == ActivityKind.ThreadReply && it.unread }
    }
}
