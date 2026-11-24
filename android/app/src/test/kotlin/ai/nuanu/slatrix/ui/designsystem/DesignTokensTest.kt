package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import com.google.gson.JsonElement
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DesignTokensTest {
    @Test fun `both themes match the shared token contract`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "design/tokens.json").readText()).asJsonObject
        val android = spec["android"].asJsonObject
        for (dark in listOf(false, true)) {
            val expected = android["colors"].asJsonObject.entrySet().associate { (role, value) ->
                role to color(if (value.isJsonObject) value.asJsonObject[if (dark) "dark" else "light"] else value).toArgb()
            }
            assertEquals("dark=$dark", expected, DesignTokens.colors(dark).mapValues { it.value.toArgb() })
        }
        assertEquals(spec["fileColors"].asJsonObject.entrySet().associate { it.key to color(it.value).toArgb() }, DesignTokens.fileColors.mapValues { it.value.toArgb() })
        assertEquals(spec["avatarColors"].asJsonArray.map { color(it).toArgb() }, DesignTokens.avatarColors.map { it.toArgb() })
        assertEquals(android["radius"].asJsonObject.entrySet().associate { it.key to it.value.asInt }, DesignTokens.radii)
    }

    @Test fun `incoming bubbles are borderless and wallpaper doodles stay visible yet calm`() {
        val light = DesignTokens.colors(false)
        val dark = DesignTokens.colors(true)
        assertEquals(0f, light.getValue("bubbleEdge").alpha, 0.0001f)
        assertEquals(0f, dark.getValue("bubbleEdge").alpha, 0.0001f)
        assertEquals(Color(0xff1a64d6).copy(alpha = 0.07f).toArgb(), light.getValue("wallpaperDoodle").toArgb())
        assertEquals(Color(0xffffffff).copy(alpha = 0.045f).toArgb(), dark.getValue("wallpaperDoodle").toArgb())
    }

    @Test fun `file tiles use soft 14 percent tint and meet WCAG icon contrast across light, dark, and outgoing bubbles`() {
        fun contrast(first: Color, second: Color): Float {
            val (dark, light) = listOf(first.luminance(), second.luminance()).sorted()
            return (light + 0.05f) / (dark + 0.05f)
        }
        for (dark in listOf(false, true)) {
            val colors = AppColors(DesignTokens.colors(dark), dark)
            val onFill = colors.onFill
            for ((kind, base) in DesignTokens.fileColors) {
                val fill = colors.fileTileFill(base)
                val icon = colors.fileTileIcon(base)
                assertEquals("dark=$dark $kind alpha", 0.14f, fill.alpha, 0.005f)
                val onBubble = fill.compositeOver(colors.bubbleIn)
                val ratio = contrast(icon, onBubble)
                assertTrue("dark=$dark $kind contrast on incoming bubble was $ratio", ratio >= 3.0f)
                val onCanvas = fill.compositeOver(colors.canvas)
                val canvasRatio = contrast(icon, onCanvas)
                assertTrue("dark=$dark $kind contrast on canvas was $canvasRatio", canvasRatio >= 3.0f)

                val outBg = onFill.fileTileFill(base).compositeOver(colors.accentFill)
                val outRatio = contrast(onFill.fileTileIcon(base), outBg)
                assertTrue("dark=$dark $kind contrast on outgoing bubble was $outRatio", outRatio >= 3.0f)
            }
        }
    }

    @Test fun `in dark theirs stand off every stop of the wallpaper`() {
        val colors = DesignTokens.colors(true)
        for (stop in listOf("wallpaper")) {
            val (a, b) = listOf(colors.getValue("bubbleIn").luminance(), colors.getValue(stop).luminance()).sorted()
            assertTrue(stop, (b + 0.05f) / (a + 0.05f) >= 1.25f)
        }
    }

    @Test fun `text and filled buttons meet WCAG AA contrast and dark surfaces step upward`() {
        fun contrast(first: Color, second: Color): Float {
            val (dark, light) = listOf(first.luminance(), second.luminance()).sorted()
            return (light + 0.05f) / (dark + 0.05f)
        }
        for (dark in listOf(false, true)) {
            val colors = DesignTokens.colors(dark)
            for (surface in listOf("canvas", "raised", "bubbleIn")) {
                assertTrue("dark=$dark textTertiary/$surface", contrast(colors.getValue("textTertiary"), colors.getValue(surface)) >= 4.5f)
            }
            assertTrue("dark=$dark onAccent/accentFill", contrast(colors.getValue("onAccent"), colors.getValue("accentFill")) >= 4.5f)
            assertTrue("dark=$dark onAccent/destructiveFill", contrast(colors.getValue("onAccent"), colors.getValue("destructiveFill")) >= 4.5f)
            for (surface in listOf("canvas", "raised", "overlay", "wallpaper")) {
                assertTrue("dark=$dark destructive/$surface", contrast(colors.getValue("destructive"), colors.getValue(surface)) >= 4.5f)
            }
            assertTrue("dark=$dark warning/canvas", contrast(colors.getValue("warning"), colors.getValue("canvas")) >= 4.5f)
        }
        val dark = DesignTokens.colors(true)
        val elevation = listOf("sunken", "canvas", "raised", "overlay").map { dark.getValue(it).luminance() }
        assertTrue("dark surfaces step upward: $elevation", elevation.zipWithNext().all { (a, b) -> a < b })
    }

    private fun color(value: JsonElement): Color {
        val parts = value.asString.removePrefix("#").split('/')
        return Color(0xff000000 or parts[0].toLong(16)).copy(alpha = parts.getOrNull(1)?.toFloat() ?: 1f)
    }
}
