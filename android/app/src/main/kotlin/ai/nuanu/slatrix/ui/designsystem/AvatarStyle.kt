package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.material3.Typography
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

object AvatarStyle {
    val label = Typography().labelLarge.copy(fontWeight = FontWeight.Bold)

    /** Shrinks two wide initials to fit a fixed tile rather than widen it. */
    val fit = TextAutoSize.StepBased(minFontSize = 6.sp, maxFontSize = label.fontSize)
}
