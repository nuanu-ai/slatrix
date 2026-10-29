package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.ui.graphics.luminance
import org.junit.Assert.assertTrue
import org.junit.Test

class AvatarContrastTest {
    // capability: people.avatars
    @Test fun initialsMeetTheContrastRequirementAcrossEveryAvatarColor() {
        val minimum = 4.5f
        val foreground = DesignTokens.colors(false, SidebarPalette.Aubergine).getValue("onAccent").luminance()
        for (background in DesignTokens.avatarColors) {
            val luminance = background.luminance()
            val ratio = (maxOf(foreground, luminance) + 0.05f) / (minOf(foreground, luminance) + 0.05f)
            assertTrue("Avatar initials need $minimum:1 contrast, got $ratio", ratio >= minimum)
        }
    }
}
