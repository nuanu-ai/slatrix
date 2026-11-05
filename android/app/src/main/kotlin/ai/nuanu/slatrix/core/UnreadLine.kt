package ai.nuanu.slatrix.core

/** Where Slack's New line goes and where an unread conversation opens; the cases are in spec/unread-line.json. */
object UnreadLine {
    /** One timeline item as the line sees it: the SDK's read marker, or the remote message it shows and whether it's yours. */
    data class Mark(val readMarker: Boolean = false, val shown: String? = null, val own: Boolean = false)

    /** The first shown message from someone else after the read marker, which the line goes above. */
    fun first(marks: List<Mark>): String? {
        val marker = marks.indexOfFirst { it.readMarker }
        if (marker < 0) return null
        return marks.subList(marker + 1, marks.size).firstOrNull { it.shown != null && !it.own }?.shown
    }

    /** The fully-read event an unread conversation opens at; one only marked unread by hand has nothing to resume. */
    fun resumeAt(room: RoomUnread, fullyRead: String?): String? = fullyRead?.takeIf {
        room.membership == "join" && (room.messages > 0 || room.notifications > 0) && isMatrixId(it, "$")
    }
}
