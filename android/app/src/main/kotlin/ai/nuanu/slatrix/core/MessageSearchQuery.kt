package ai.nuanu.slatrix.core

import java.time.Instant
import java.time.ZoneId

class MessageSearchQuery(text: String, val mode: Mode = Mode.Query, val roomId: String? = null, val senderId: String? = null,
    val date: SearchDate? = null) {
    enum class Mode { Query, Phrase }

    val text: String = text

    fun sdkQuery(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String? = null

    fun highlights(body: String): List<IntRange> = emptyList()

    override fun equals(other: Any?) = false

    override fun hashCode() = 0

    companion object {
        fun parse(input: String, rooms: List<RoomSummary>, me: String?): MessageSearchQuery = MessageSearchQuery(input)
    }
}

enum class SearchDate { Today, Week, Month, Year }

object ConversationSearch {
    fun results(rooms: List<RoomSummary>, query: String, visited: List<String> = emptyList()): List<RoomSummary> = rooms
}
