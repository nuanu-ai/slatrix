package ai.nuanu.slatrix.core

object WorkspaceRail {
    const val AllToken = "__all__"

    fun entries(spaces: List<SpaceSummary>, rooms: List<RoomSummary>): List<SpaceSummary?> = emptyList()

    fun choose(remembered: String?, showing: RoomSummary?, spaces: List<SpaceSummary>, rooms: List<RoomSummary>): String? = remembered
}
