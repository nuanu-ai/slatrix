package ai.nuanu.slatrix.ui.designsystem

import ai.nuanu.slatrix.core.AndroidTheme
import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w412dp-h892dp-420dpi")
class SlatrixThemeTest {
    @get:Rule val compose = createComposeRule()

    // capability: app.themes
    @Test fun allSixThemesMeetWcagContrastInLightDarkAndHighContrast() {
        val captured = linkedMapOf<Triple<AndroidTheme, Boolean, Boolean>, Pair<AppColors, Color>>()
        compose.setContent {
            for (theme in AndroidTheme.entries) {
                for (dark in listOf(false, true)) {
                    for (highContrast in listOf(false, true)) {
                        SlatrixTheme(dark = dark, theme = theme, increaseContrast = highContrast) {
                            captured[Triple(theme, dark, highContrast)] = SlatrixTheme.colors to MaterialTheme.colorScheme.primary
                        }
                    }
                }
            }
        }
        compose.waitForIdle()

        // Every colored theme produces a distinct accent fill from Neutral.
        val neutralAccent = captured.getValue(Triple(AndroidTheme.Neutral, false, false)).first.accentFill.toArgb()
        for (colored in listOf(AndroidTheme.Aubergine, AndroidTheme.Jade, AndroidTheme.Ocean)) {
            assertNotEquals("${colored.key} has its own accent fill", neutralAccent,
                captured.getValue(Triple(colored, false, false)).first.accentFill.toArgb())
        }

        for (theme in AndroidTheme.entries) {
            for (dark in listOf(false, true)) {
                val normal = captured.getValue(Triple(theme, dark, false)).first
                for (highContrast in listOf(false, true)) {
                    val (colors, primary) = captured.getValue(Triple(theme, dark, highContrast))
                    val tag = "${theme.key} dark=$dark hc=$highContrast"
                    assertEquals("$tag MaterialTheme.primary tracks accentFill", colors.accentFill.toArgb(), primary.toArgb())
                    assertEquals("$tag bubbleEdge stays transparent", 0f, colors.bubbleEdge.alpha, 0.0001f)
                    assertEquals("$tag wallpaperDoodle alpha", if (dark) 0.045f else 0.07f, colors.wallpaperDoodle.alpha, 0.002f)

                    for ((name, fg) in listOf(
                        "textPrimary" to colors.textPrimary,
                        "textBody" to colors.textBody,
                        "textSecondary" to colors.textSecondary,
                        "textTertiary" to colors.textTertiary,
                    )) {
                        for ((surfName, bg) in listOf("canvas" to colors.canvas, "raised" to colors.raised, "bubbleIn" to colors.bubbleIn)) {
                            val ratio = contrast(fg, bg)
                            assertTrue("$tag $name/$surfName=$ratio", ratio >= 4.5f)
                        }
                    }
                    assertTrue("$tag onAccent/accentFill", contrast(colors.onAccent, colors.accentFill) >= 4.5f)
                    assertTrue("$tag destructive/canvas", contrast(colors.destructive, colors.canvas) >= 4.5f)
                    val chipBg = colors.dateChip.compositeOver(colors.wallpaper)
                    assertTrue("$tag onDateChip/dateChip", contrast(colors.onDateChip, chipBg) >= 4.5f)

                    if (highContrast) {
                        assertTrue("$tag high contrast strengthens border",
                            contrast(colors.border, colors.canvas) > contrast(normal.border, normal.canvas))
                        assertTrue("$tag high contrast strengthens textSecondary",
                            contrast(colors.textSecondary, colors.canvas) > contrast(normal.textSecondary, normal.canvas))
                        if (dark) {
                            assertEquals("$tag dark high-contrast canvas is pure black", Color.Black.toArgb(), colors.canvas.toArgb())
                        }
                    }
                }
            }
        }
    }

    // capability: app.themes
    @Test fun chatWallpaperToggleShowsOrHidesDoodlesOnChannelAndThreadScreens() {
        val showDoodles = mutableStateOf(true)
        val threadRoot = mutableStateOf<String?>(null)
        val theme = mutableStateOf(AndroidTheme.Aubergine)
        lateinit var view: View
        var wallpaperColor = Color.Unspecified
        val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)

        compose.setContent {
            view = LocalView.current
            SlatrixTheme(dark = false, theme = theme.value, chatWallpaper = showDoodles.value) {
                wallpaperColor = SlatrixTheme.colors.wallpaper
                LiveChannelScreen(
                    room = room,
                    state = ConversationState(loading = false, hasMore = false),
                    composer = ComposerState(loading = false),
                    onDraft = {},
                    onSend = {},
                    onBack = {},
                    onLoadOlder = {},
                    onRead = {},
                    onRetry = {},
                    onRetrySend = {},
                    onDeleteUnsent = {},
                    threadRoot = threadRoot.value,
                )
            }
        }

        fun countDoodlePixels(): Int {
            compose.waitForIdle()
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
            val expected = wallpaperColor.toArgb()
            // Sample the open middle band of the conversation (clear of header, intro, and composer).
            var nonBase = 0
            val top = (view.height * 0.35f).toInt()
            val bottom = (view.height * 0.65f).toInt()
            val left = (view.width * 0.1f).toInt()
            val right = (view.width * 0.9f).toInt()
            for (y in top until bottom step 2) {
                for (x in left until right step 2) {
                    if (bitmap.getPixel(x, y) != expected) nonBase++
                }
            }
            return nonBase
        }

        // Channel mode: doodles drawn when ON, pure tinted wallpaper when OFF.
        assertTrue("Channel shows doodle pattern when chatWallpaper is on", countDoodlePixels() > 50)
        compose.runOnIdle { showDoodles.value = false }
        assertEquals("Channel hides doodle pattern while keeping solid tinted wallpaper", 0, countDoodlePixels())

        // Thread mode: same independent toggle works on threads and across other themes.
        compose.runOnIdle {
            threadRoot.value = "\$root"
            theme.value = AndroidTheme.Jade
            showDoodles.value = true
        }
        assertTrue("Thread shows doodle pattern when chatWallpaper is on", countDoodlePixels() > 50)
        compose.runOnIdle { showDoodles.value = false }
        assertEquals("Thread hides doodle pattern while keeping solid tinted wallpaper", 0, countDoodlePixels())
    }

    // capability: app.themes
    @Test fun wallpaperModifierRespectsShowDoodlesFlagAcrossAllThemes() {
        val showDoodles = mutableStateOf(true)
        val theme = mutableStateOf(AndroidTheme.Neutral)
        lateinit var view: View
        var baseWallpaper = Color.Unspecified
        compose.setContent {
            view = LocalView.current
            SlatrixTheme(dark = true, theme = theme.value, chatWallpaper = showDoodles.value) {
                baseWallpaper = SlatrixTheme.colors.wallpaper
                Box(Modifier.size(UiMetrics.WallpaperTile).wallpaper())
            }
        }

        for (candidate in AndroidTheme.entries) {
            compose.runOnIdle {
                theme.value = candidate
                showDoodles.value = true
            }
            compose.waitForIdle()
            val withDoodles = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
            val hasDoodle = (0 until withDoodles.height step 2).any { y ->
                (0 until withDoodles.width step 2).any { x -> withDoodles.getPixel(x, y) != baseWallpaper.toArgb() }
            }
            assertTrue("${candidate.key} draws doodles when enabled", hasDoodle)

            compose.runOnIdle { showDoodles.value = false }
            compose.waitForIdle()
            val solidOnly = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888).also { view.draw(Canvas(it)) }
            val anyDoodle = (0 until solidOnly.height step 2).any { y ->
                (0 until solidOnly.width step 2).any { x -> solidOnly.getPixel(x, y) != baseWallpaper.toArgb() }
            }
            assertFalse("${candidate.key} renders only solid wallpaper when doodles are off", anyDoodle)
        }
    }

    private fun contrast(first: Color, second: Color): Float {
        val (dark, light) = listOf(first.luminance(), second.luminance()).sorted()
        return (light + 0.05f) / (dark + 0.05f)
    }
}
