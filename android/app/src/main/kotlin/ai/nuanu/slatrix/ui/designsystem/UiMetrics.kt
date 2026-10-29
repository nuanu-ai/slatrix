package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.ui.unit.dp

object UiMetrics {
    val GapTiny = 4.dp
    val GapSmall = 8.dp
    val GapMedium = 12.dp
    val GapLarge = 16.dp
    val GapSection = 24.dp
    val Avatar = 40.dp
    val ProfileAvatar = 56.dp
    val Touch = 48.dp
    /** Slack's conversation list row. */
    val ListRow = 44.dp
    val WorkspaceRow = 56.dp
    val SearchField = 40.dp
    val SmallIcon = 16.dp
    val Icon = 20.dp
    val LargeIcon = 24.dp
    val Divider = 1.dp
    val CompactAvatar = 24.dp
    val ListAvatar = 36.dp
    val HeaderAvatar = 32.dp
    val RootHeaderHeight = 60.dp
    val ComposerMinHeight = 64.dp
    val FormWidth = 480.dp
    /** Slack's cards at the top of Home, such as Later. */
    val HomeCard = 100.dp
    const val ProgressDelayMillis = 400L
    const val NoticeMillis = 4_000L
    /** How long a message jumped to stays highlighted, as on the Mac. */
    const val HighlightMillis = 1_500L
    val ExpandedWidth = 600.dp
    /** Slack's message sheet: its icons and its Reply tile. */
    val SheetIcon = 24.dp
    val ActionTile = 86.dp
    /** The accent rule beside a quoted message. */
    val QuoteBar = 3.dp
    /** About five @ suggestions before the list scrolls. */
    val MentionListHeight = 240.dp
    /** Reaction chips and the thread replies line, as tall as Slack Android's. */
    val ChipHeight = 32.dp
    /** A list's indent, in multiples of the text size, as on the Mac. */
    const val ListIndentScale = 1.6f
    /** Code reads a little smaller than the text around it, as on the Mac. */
    const val CodeTextScale = 0.9f
}
