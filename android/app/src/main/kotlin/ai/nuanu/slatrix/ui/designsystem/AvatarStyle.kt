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

    /**
     * An avatar color shaded from itself at the top down to a little darker, so a tile has some depth. Darker, not
     * lighter: the palette sits just past the initials' contrast requirement.
     */
    fun fill(color: Color): Brush = Brush.verticalGradient(shades(color))

    /** The fill's colors, top to bottom; the initials sit on all of them. */
    fun shades(color: Color): List<Color> = listOf(color, lerp(color, Color.Black, BottomShade))

    private const val BottomShade = 0.16f
}
