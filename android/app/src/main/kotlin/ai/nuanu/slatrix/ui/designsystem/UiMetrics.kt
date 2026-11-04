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
    /** Slack's floating + button. */
    val Fab = 56.dp
    /** A profile page's picture. */
    val ProfilePhoto = 120.dp
    val Touch = 48.dp
    /** Slack's conversation list row. */
    val ListRow = 44.dp
    val WorkspaceRow = 56.dp
    val SearchField = 40.dp
    val SmallIcon = 16.dp
    val Icon = 20.dp
    val LargeIcon = 24.dp
    val Divider = 1.dp
    val Hairline = 0.5.dp
    /** A grey bar standing in for a line of text while it loads. */
    val SkeletonLine = 12.dp
    /** Design B's two-line conversation row and its 48 dp avatar or channel tile. */
    val ConversationRow = 72.dp
    val RowAvatar = 48.dp
    /** A sender's picture beside their bubbles. */
    val FeedAvatar = 32.dp
    /** Material's search bar on Home. */
    val SearchBar = 56.dp
    /** The floating tab capsule, its inset around the selected tab, and its gap above the screen's bottom. */
    val TabBar = 64.dp
    val TabInset = 4.dp
    /** A chat header's row, over the glass. */
    val HeaderRow = 64.dp
    val SectionHeader = 40.dp
    /** Home's one-line row. */
    val CompactRow = 48.dp
    val Badge = 20.dp
    val ChannelTile = 40.dp
    /** The faces on a thread's replies bar. */
    val Facepile = 20.dp
    val ThreadBar = 40.dp
    /** The share of the width your bubble leaves on its far side, so a long one reaches about 85%, as in Telegram. */
    const val BubbleGutter = 0.12f
    /** Theirs leave a gutter that grows with the phone, from narrow at 320 dp to wide at 412 dp, past their picture's room. */
    val IncomingGutterNarrow = 24.dp
    val IncomingGutterWide = 56.dp
    val NarrowPhone = 320.dp
    val WidePhone = 412.dp
    val GlassBlur = 24.dp
    /** The message menu: its card's width and rows, the reaction bar and its buttons, and the blur of the screen behind. */
    val MenuWidth = 252.dp
    val MenuItem = 44.dp
    val MenuInset = 6.dp
    val ReactionBar = 52.dp
    val ReactionButton = 40.dp
    val MenuBlur = 14.dp
    val GlassLift = 12.dp
    val WallpaperGrid = 20.dp
    val WallpaperDot = 1.dp
    /** The grab handle atop a bottom sheet. */
    val SheetHandleWidth = 32.dp
    val SheetHandleHeight = 4.dp
    /** How far down a sheet is dragged, as a share of its height, before letting go closes it. */
    const val SheetDismissShare = 0.25f
    /** How fast a flick down closes a sheet, per second. */
    val SheetDismissVelocity = 1_000.dp
    val CompactAvatar = 24.dp
    val ListAvatar = 36.dp
    val HeaderAvatar = 32.dp
    val ComposerMinHeight = 64.dp
    val FormWidth = 480.dp
    const val ProgressDelayMillis = 400L
    const val NoticeMillis = 4_000L
    /** How long the connection must be down before the offline banner shows, as on the Mac. */
    const val ConnectionNoticeMillis = 2_000L
    /** How long a message jumped to stays highlighted, as on the Mac. */
    const val HighlightMillis = 1_500L
    /** Slack's message sheet: its icons and its Reply tile. */
    val SheetIcon = 24.dp
    val ActionTile = 86.dp
    /** The accent rule beside a quoted message. */
    val QuoteBar = 3.dp
    /** About five @ suggestions before the list scrolls. */
    val MentionListHeight = 240.dp
    /** Reaction chips and the thread replies line, as tall as Slack Android's. */
    val ChipHeight = 32.dp
    /** The tallest an inline image gets; wider ones fill the row. */
    val MediaMaxHeight = 320.dp
    val FileTile = 40.dp
    /** What one of an image's own pixels takes inline, so a small image keeps its size, as on the Mac. */
    val MediaPixel = 1.dp
    /** The most pixels a side of the full-screen picture asks for. */
    const val ViewerPixels = 2_048
    const val ViewerMaxZoom = 5f
    const val ViewerDoubleTapZoom = 2.5f
    /** A list's indent, in multiples of the text size, as on the Mac. */
    const val ListIndentScale = 1.6f
    /** Code reads a little smaller than the text around it, as on the Mac. */
    const val CodeTextScale = 0.9f
}
