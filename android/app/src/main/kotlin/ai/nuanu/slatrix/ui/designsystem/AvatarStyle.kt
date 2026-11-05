package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp

import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

object AvatarStyle {
    val label = SlatrixTypography.labelLarge.copy(fontWeight = FontWeight.Bold)

    /** Shrinks two wide initials to fit a fixed tile rather than widen it. */
    val fit = TextAutoSize.StepBased(minFontSize = 6.sp, maxFontSize = label.fontSize)

    /** An avatar color shaded from a little lighter at the top down to itself, so a tile has some depth. */
    fun fill(color: Color): Brush = Brush.verticalGradient(listOf(lerp(color, Color.White, TopLift), color))

    private const val TopLift = 0.16f
}
