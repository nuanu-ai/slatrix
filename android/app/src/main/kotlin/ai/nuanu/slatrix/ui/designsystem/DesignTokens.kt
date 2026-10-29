package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.ui.graphics.Color

enum class SidebarPalette {
    Aubergine, Clementine, Banana, Jade, Lagoon, Barbra, Gray, MoodIndigo;

    /** The name Slack and the Mac show. */
    val label: String get() = if (this == MoodIndigo) "Mood Indigo" else name

    val tokenName: String get() = name.replaceFirstChar { it.lowercase() }
}

object DesignTokens {
    fun colors(dark: Boolean, palette: SidebarPalette): Map<String, Color> = if (dark) {
        mapOf(
            "textPrimary" to Color(0xfff5f5f5),
            "textBody" to Color(0xffd1d2d3),
            "textSecondary" to Color(0xffabadb1),
            "textTertiary" to Color(0xff7c7f84),
            "canvas" to Color(0xff1c1d21),
            "raised" to Color(0xff24262a),
            "sunken" to Color(0xff27282c),
            "overlay" to Color(0xff222529),
            "tooltip" to Color(0xff111214),
            "onTooltip" to Color(0xffffffff),
            "scrim" to Color(0xff000000).copy(alpha = 0.48f),
            "sidebar" to when (palette) {
                SidebarPalette.Aubergine -> Color(0xff211323)
                SidebarPalette.Clementine -> Color(0xff24170e)
                SidebarPalette.Banana -> Color(0xff211e0f)
                SidebarPalette.Jade -> Color(0xff15231d)
                SidebarPalette.Lagoon -> Color(0xff13212b)
                SidebarPalette.Barbra -> Color(0xff25121b)
                SidebarPalette.Gray -> Color(0xff17181a)
                SidebarPalette.MoodIndigo -> Color(0xff161833)
            },
            "frame" to when (palette) {
                SidebarPalette.Aubergine -> Color(0xff350d36)
                SidebarPalette.Clementine -> Color(0xff4a2410)
                SidebarPalette.Banana -> Color(0xff3a3210)
                SidebarPalette.Jade -> Color(0xff142b23)
                SidebarPalette.Lagoon -> Color(0xff0e293b)
                SidebarPalette.Barbra -> Color(0xff3f1328)
                SidebarPalette.Gray -> Color(0xff202124)
                SidebarPalette.MoodIndigo -> Color(0xff1e2154)
            },
            "border" to Color(0xff383a3e),
            "borderStrong" to Color(0xff5a5c61),
            "hover" to Color(0xffffffff).copy(alpha = 0.08f),
            "pressed" to Color(0xffffffff).copy(alpha = 0.14f),
            "selection" to when (palette) {
                SidebarPalette.Aubergine -> Color(0xff713783)
                SidebarPalette.Clementine -> Color(0xff8a4a1f)
                SidebarPalette.Banana -> Color(0xff6b5a12)
                SidebarPalette.Jade -> Color(0xff2d6654)
                SidebarPalette.Lagoon -> Color(0xff195b7c)
                SidebarPalette.Barbra -> Color(0xff7a2a52)
                SidebarPalette.Gray -> Color(0xff293b94)
                SidebarPalette.MoodIndigo -> Color(0xff3a3f99)
            },
            "selectionStrong" to when (palette) {
                SidebarPalette.Aubergine -> Color(0xff7c3085)
                SidebarPalette.Clementine -> Color(0xffb35418)
                SidebarPalette.Banana -> Color(0xff8f6c00)
                SidebarPalette.Jade -> Color(0xff2a7d5f)
                SidebarPalette.Lagoon -> Color(0xff0f7aa8)
                SidebarPalette.Barbra -> Color(0xffb0306a)
                SidebarPalette.Gray -> Color(0xff1164a3)
                SidebarPalette.MoodIndigo -> Color(0xff4b52c9)
            },
            "selectionText" to Color(0xffffffff),
            "highlight" to Color(0xfff2c744).copy(alpha = 0.3f),
            "focusRing" to Color(0xff1d9bd1),
            "accent" to Color(0xff8195ff),
            "accentTint" to Color(0xff8195ff).copy(alpha = 0.2f),
            "onAccent" to Color(0xffffffff),
            "buttonPrimary" to Color(0xff007a5a),
            "success" to Color(0xff007a5a),
            "destructive" to Color(0xffe01e5a),
            "warning" to Color(0xfff0a030),
            "mention" to Color(0xffe01e5a),
            "mentionText" to Color(0xff1d9bd1),
            "mentionFill" to Color(0xff1d9bd1).copy(alpha = 0.18f),
            "mentionYouText" to Color(0xfff2c744),
            "mentionYouFill" to Color(0xfff2c744).copy(alpha = 0.2f),
            "presenceActive" to Color(0xff2bac76),
            "presenceAway" to Color(0xffabadb1),
            "mediaBackdrop" to Color(0xff1a1b1e),
            "mediaControl" to Color(0xff000000).copy(alpha = 0.6f),
            "mediaShade" to Color(0xff000000).copy(alpha = 0.5f),
            "onMedia" to Color(0xffffffff),
            "onMediaEdge" to Color(0xff000000).copy(alpha = 0.4f),
        )
    } else {
        mapOf(
            "textPrimary" to Color(0xff1d1c1d),
            "textBody" to Color(0xff1d1c1d),
            "textSecondary" to Color(0xff616061),
            "textTertiary" to Color(0xff8d8c8d),
            "canvas" to Color(0xffffffff),
            "raised" to Color(0xfff8f8f8),
            "sunken" to Color(0xfff4f4f4),
            "overlay" to Color(0xffffffff),
            "tooltip" to Color(0xff1d1c1d),
            "onTooltip" to Color(0xffffffff),
            "scrim" to Color(0xff000000).copy(alpha = 0.32f),
            "sidebar" to Color(0xfff8f8f8),
            "frame" to when (palette) {
                SidebarPalette.Aubergine -> Color(0xffede4ef)
                SidebarPalette.Clementine -> Color(0xfff8e9dd)
                SidebarPalette.Banana -> Color(0xfff7f1d9)
                SidebarPalette.Jade -> Color(0xffe4eee7)
                SidebarPalette.Lagoon -> Color(0xffe2edf4)
                SidebarPalette.Barbra -> Color(0xfff6e4ec)
                SidebarPalette.Gray -> Color(0xfff0f0f0)
                SidebarPalette.MoodIndigo -> Color(0xffe6e7f6)
            },
            "border" to Color(0xffe3e3e3),
            "borderStrong" to Color(0xffbbbabb),
            "hover" to Color(0xff1d1c1d).copy(alpha = 0.06f),
            "pressed" to Color(0xff1d1c1d).copy(alpha = 0.11f),
            "selection" to when (palette) {
                SidebarPalette.Aubergine -> Color(0xfff0e6f4)
                SidebarPalette.Clementine -> Color(0xfffbe9dc)
                SidebarPalette.Banana -> Color(0xfffaf2cf)
                SidebarPalette.Jade -> Color(0xffdeeee5)
                SidebarPalette.Lagoon -> Color(0xffdceef8)
                SidebarPalette.Barbra -> Color(0xfff9e4ee)
                SidebarPalette.Gray -> Color(0xffe7ebff)
                SidebarPalette.MoodIndigo -> Color(0xffe6e8fb)
            },
            "selectionStrong" to when (palette) {
                SidebarPalette.Aubergine -> Color(0xff611f69)
                SidebarPalette.Clementine -> Color(0xffa84c12)
                SidebarPalette.Banana -> Color(0xff8a6a00)
                SidebarPalette.Jade -> Color(0xff1d6b50)
                SidebarPalette.Lagoon -> Color(0xff0b5c8a)
                SidebarPalette.Barbra -> Color(0xff9e2a5e)
                SidebarPalette.Gray -> Color(0xff1164a3)
                SidebarPalette.MoodIndigo -> Color(0xff3a40b0)
            },
            "selectionText" to Color(0xffffffff),
            "highlight" to Color(0xfff2c744).copy(alpha = 0.5f),
            "focusRing" to Color(0xff1d9bd1),
            "accent" to Color(0xff334ec9),
            "accentTint" to Color(0xff334ec9).copy(alpha = 0.1f),
            "onAccent" to Color(0xffffffff),
            "buttonPrimary" to Color(0xff007a5a),
            "success" to Color(0xff007a5a),
            "destructive" to Color(0xffe01e5a),
            "warning" to Color(0xffc46800),
            "mention" to Color(0xffe01e5a),
            "mentionText" to Color(0xff1264a3),
            "mentionFill" to Color(0xff1d9bd1).copy(alpha = 0.1f),
            "mentionYouText" to Color(0xff1264a3),
            "mentionYouFill" to Color(0xfff2c744).copy(alpha = 0.4f),
            "presenceActive" to Color(0xff2bac76),
            "presenceAway" to Color(0xff616061),
            "mediaBackdrop" to Color(0xff1a1b1e),
            "mediaControl" to Color(0xff000000).copy(alpha = 0.6f),
            "mediaShade" to Color(0xff000000).copy(alpha = 0.5f),
            "onMedia" to Color(0xffffffff),
            "onMediaEdge" to Color(0xff000000).copy(alpha = 0.4f),
        )
    }

    val fileColors: Map<String, Color> = mapOf(
        "pdf" to Color(0xffd93a3a),
        "document" to Color(0xff2f6fde),
        "spreadsheet" to Color(0xff1f8f55),
        "presentation" to Color(0xffe8771e),
        "archive" to Color(0xff7d8086),
        "code" to Color(0xff5b55c9),
        "audio" to Color(0xffc23d84),
        "video" to Color(0xff8a4fd1),
        "image" to Color(0xff1b93a8),
        "generic" to Color(0xff5c6878),
    )

    val avatarColors: List<Color> = listOf(
        Color(0xff78669d),
        Color(0xff447389),
        Color(0xff9a6d4c),
        Color(0xff5d7f5a),
        Color(0xffa16576),
        Color(0xff5d78a0),
    )

    val radii: Map<String, Int> = mapOf(
        "small" to 4,
        "default" to 6,
        "large" to 8,
        "panel" to 12,
    )
}
