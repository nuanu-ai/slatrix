package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp

/** Material 3's type scale in the system's Roboto, in sp, so it grows with the phone's font size. */
internal val SlatrixTypography = Typography()

/** A message's text: body large with a messenger's tighter leading, so a long message reads as one block in its bubble. */
val Typography.message: TextStyle get() = bodyLarge.copy(lineHeight = 22.sp)
