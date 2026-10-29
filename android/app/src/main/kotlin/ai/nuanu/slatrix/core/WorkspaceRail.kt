package ai.nuanu.slatrix.core

/** The workspaces the switcher offers, and the one that opens. A null entry is All: every conversation. */
object WorkspaceRail {
    /** How a remembered choice of All is stored. */
    const val AllToken = "__all__"

    /** Top-level workspaces in the order given (name order), then All while some channel belongs to no workspace. */
    fun entries(spaces: List<SpaceSummary>, rooms: List<RoomSummary>): List<SpaceSummary?> {
        val orphans = rooms.any { !it.direct && it.spaceIds.isEmpty() }
        return spaces.filter { it.isTopLevel } + if (orphans) listOf(null) else emptyList()
    }

    /**
     * The remembered workspace while it is still there, else the one holding the conversation on screen, else the one
     * with the most channels, so a first launch lands where the person actually works.
     */
    fun choose(remembered: String?, showing: RoomSummary?, spaces: List<SpaceSummary>, rooms: List<RoomSummary>): String? {
        val rail = entries(spaces, rooms)
        if (remembered == AllToken && null in rail) return null
        if (remembered != null && spaces.any { it.id == remembered }) return remembered
        if (showing != null && !showing.direct) spaces.firstOrNull { it.isTopLevel && it.id in showing.spaceIds }?.let { return it.id }
        return rail.filterNotNull().maxByOrNull { space -> rooms.count { !it.direct && space.id in it.spaceIds } }?.id
    }
}
