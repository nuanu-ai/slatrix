package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.ui.graphics.luminance
import org.junit.Assert.assertTrue
import org.junit.Test

class AvatarContrastTest {
    @Test fun initialsMeetTheContrastRequirementAcrossEveryAvatarColor() {
        val style = AvatarStyle.label
        val largeBoldText = style.fontSize.value >= 18.667f && (style.fontWeight?.weight ?: 400) >= 700
        val minimum = if (largeBoldText) 3f else 4.5f
        val foreground = DesignTokens.colors(false, SidebarPalette.Aubergine).getValue("onAccent").luminance()
        for (background in DesignTokens.avatarColors) {
            val luminance = background.luminance()
            val ratio = (maxOf(foreground, luminance) + 0.05f) / (minOf(foreground, luminance) + 0.05f)
            assertTrue("Avatar initials need $minimum:1 contrast, got $ratio", ratio >= minimum)
        }
    }
}
