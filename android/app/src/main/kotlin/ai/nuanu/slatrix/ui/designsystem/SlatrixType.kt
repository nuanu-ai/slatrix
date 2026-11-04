package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp

/**
 * Material 3's type scale in the system's Roboto, in sp, so it grows with the phone's font size. Set without Material's
 * extra tracking, as the boards and the messengers they follow set it; spaced out, small text on a narrow phone reads loose.
 */
internal val SlatrixTypography = Typography().run {
    fun TextStyle.set() = copy(letterSpacing = 0.sp)
    Typography(displayLarge.set(), displayMedium.set(), displaySmall.set(), headlineLarge.set(), headlineMedium.set(),
        headlineSmall.set(), titleLarge.set(), titleMedium.set(), titleSmall.set(), bodyLarge.set(), bodyMedium.set(),
        bodySmall.set(), labelLarge.set(), labelMedium.set(), labelSmall.set())
}

/** A message's text: body large with a messenger's tighter leading, so a long message reads as one block in its bubble. */
val Typography.message: TextStyle get() = bodyLarge.copy(lineHeight = 22.sp)
