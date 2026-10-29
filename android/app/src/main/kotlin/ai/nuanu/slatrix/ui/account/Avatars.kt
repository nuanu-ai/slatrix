package ai.nuanu.slatrix.ui.account

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.ImageBitmap

/** Loads a picture for an avatar URL at a size in pixels, or null while there is none. */
typealias AvatarLoader = suspend (url: String, sizePx: Int) -> ImageBitmap?

val LocalAvatarLoader = staticCompositionLocalOf<AvatarLoader> { { _, _ -> null } }
