package ai.nuanu.slatrix.ui.designsystem

import ai.nuanu.slatrix.core.AndroidTheme
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
    // capability: app.themes
    @Test fun `all static themes match the shared token contract`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "design/tokens.json").readText()).asJsonObject
        val android = spec["android"].asJsonObject
        val base = android["colors"].asJsonObject
        val themeOverrides = android["themes"].asJsonObject
        assertEquals(setOf("sand", "aubergine", "jade", "ocean"), themeOverrides.keySet())

        for (theme in AndroidTheme.entries.filter { it != AndroidTheme.MaterialYou }) {
            val overrides = if (theme == AndroidTheme.Neutral) null else themeOverrides[theme.key].asJsonObject
            for (dark in listOf(false, true)) {
                val expected = base.entrySet().associate { (role, defaultValue) ->
                    val raw = overrides?.get(role) ?: defaultValue
                    role to color(if (raw.isJsonObject) raw.asJsonObject[if (dark) "dark" else "light"] else raw).toArgb()
                }
                assertEquals("theme=${theme.key} dark=$dark", expected, DesignTokens.colors(theme, dark).mapValues { it.value.toArgb() })
            }
        }
        assertEquals(spec["fileColors"].asJsonObject.entrySet().associate { it.key to color(it.value).toArgb() }, DesignTokens.fileColors.mapValues { it.value.toArgb() })
        assertEquals(spec["avatarColors"].asJsonArray.map { color(it).toArgb() }, DesignTokens.avatarColors.map { it.toArgb() })
        assertEquals(android["radius"].asJsonObject.entrySet().associate { it.key to it.value.asInt }, DesignTokens.radii)
    }

    // capability: app.themes
    @Test fun `incoming bubbles stay borderless, mentionYou stays warm amber, and wallpaper doodles keep subtle opacity across all themes`() {
        val baseLight = DesignTokens.colors(AndroidTheme.Neutral, false)
        val baseDark = DesignTokens.colors(AndroidTheme.Neutral, true)
        for (theme in AndroidTheme.entries.filter { it != AndroidTheme.MaterialYou }) {
            for (highContrast in listOf(false, true)) {
                val light = themeRoles(theme, dark = false, increaseContrast = highContrast)
                val dark = themeRoles(theme, dark = true, increaseContrast = highContrast)
                assertEquals("${theme.key} light hc=$highContrast bubbleEdge", 0f, light.getValue("bubbleEdge").alpha, 0.0001f)
                assertEquals("${theme.key} dark hc=$highContrast bubbleEdge", 0f, dark.getValue("bubbleEdge").alpha, 0.0001f)
                assertEquals("${theme.key} light hc=$highContrast doodle alpha", 0.07f, light.getValue("wallpaperDoodle").alpha, 0.002f)
                assertEquals("${theme.key} dark hc=$highContrast doodle alpha", 0.045f, dark.getValue("wallpaperDoodle").alpha, 0.002f)
                if (!highContrast) {
                    assertEquals("${theme.key} light mentionYouText", baseLight.getValue("mentionYouText").toArgb(), light.getValue("mentionYouText").toArgb())
                    assertEquals("${theme.key} light mentionYouFill", baseLight.getValue("mentionYouFill").toArgb(), light.getValue("mentionYouFill").toArgb())
                    assertEquals("${theme.key} dark mentionYouText", baseDark.getValue("mentionYouText").toArgb(), dark.getValue("mentionYouText").toArgb())
                    assertEquals("${theme.key} dark mentionYouFill", baseDark.getValue("mentionYouFill").toArgb(), dark.getValue("mentionYouFill").toArgb())
                }
            }
        }
        assertEquals(Color(0xff1a64d6).copy(alpha = 0.07f).toArgb(), baseLight.getValue("wallpaperDoodle").toArgb())
        assertEquals(Color(0xffffffff).copy(alpha = 0.045f).toArgb(), baseDark.getValue("wallpaperDoodle").toArgb())
    }

    // capability: app.themes
    @Test fun `file tiles use soft 14 percent tint and meet WCAG icon contrast across all themes, light, dark, high contrast, and outgoing bubbles`() {
        for (theme in AndroidTheme.entries.filter { it != AndroidTheme.MaterialYou }) {
            for (dark in listOf(false, true)) {
                for (highContrast in listOf(false, true)) {
                    val roles = themeRoles(theme, dark, highContrast)
                    val colors = AppColors(roles, dark)
                    val onFill = colors.onFill
                    for ((kind, base) in DesignTokens.fileColors) {
                        val fill = colors.fileTileFill(base)
                        val icon = colors.fileTileIcon(base)
                        assertEquals("${theme.key} dark=$dark hc=$highContrast $kind alpha", 0.14f, fill.alpha, 0.005f)
                        val onBubble = fill.compositeOver(colors.bubbleIn)
                        val ratio = contrast(icon, onBubble)
                        assertTrue("${theme.key} dark=$dark hc=$highContrast $kind contrast on incoming bubble was $ratio", ratio >= 3.0f)
                        val onCanvas = fill.compositeOver(colors.canvas)
                        val canvasRatio = contrast(icon, onCanvas)
                        assertTrue("${theme.key} dark=$dark hc=$highContrast $kind contrast on canvas was $canvasRatio", canvasRatio >= 3.0f)

                        val outBg = onFill.fileTileFill(base).compositeOver(colors.accentFill)
                        val outRatio = contrast(onFill.fileTileIcon(base), outBg)
                        assertTrue("${theme.key} dark=$dark hc=$highContrast $kind contrast on outgoing bubble was $outRatio", outRatio >= 3.0f)
                    }
                }
            }
        }
    }

    // capability: app.themes
    @Test fun `in dark mode incoming bubbles stand off the wallpaper across every static theme and contrast mode`() {
        for (theme in AndroidTheme.entries.filter { it != AndroidTheme.MaterialYou }) {
            for (highContrast in listOf(false, true)) {
                val colors = themeRoles(theme, dark = true, increaseContrast = highContrast)
                val ratio = contrast(colors.getValue("bubbleIn"), colors.getValue("wallpaper"))
                assertTrue("${theme.key} dark hc=$highContrast bubbleIn/wallpaper=$ratio", ratio >= 1.25f)
            }
        }
    }

    // capability: app.themes
    @Test fun `all static themes meet WCAG AA contrast across light, dark, and high contrast, and dark surfaces step upward`() {
        for (theme in AndroidTheme.entries.filter { it != AndroidTheme.MaterialYou }) {
            for (dark in listOf(false, true)) {
                val normal = themeRoles(theme, dark, increaseContrast = false)
                for (highContrast in listOf(false, true)) {
                    val colors = themeRoles(theme, dark, increaseContrast = highContrast)
                    val tag = "${theme.key} dark=$dark hc=$highContrast"
                    for (role in listOf("textPrimary", "textBody", "textSecondary", "textTertiary")) {
                        for (surface in listOf("canvas", "raised", "overlay", "bubbleIn")) {
                            val ratio = contrast(colors.getValue(role), colors.getValue(surface))
                            assertTrue("$tag $role/$surface=$ratio", ratio >= 4.5f)
                        }
                    }
                    assertTrue("$tag onAccent/accentFill", contrast(colors.getValue("onAccent"), colors.getValue("accentFill")) >= 4.5f)
                    assertTrue("$tag onAccent/mention", contrast(colors.getValue("onAccent"), colors.getValue("mention")) >= 4.5f)
                    assertTrue("$tag onAccent/destructiveFill", contrast(colors.getValue("onAccent"), colors.getValue("destructiveFill")) >= 4.5f)
                    for (surface in listOf("canvas", "raised", "overlay", "bubbleIn")) {
                        assertTrue("$tag accent/$surface", contrast(colors.getValue("accent"), colors.getValue(surface)) >= 4.5f)
                    }
                    for (surface in listOf("canvas", "bubbleIn")) {
                        val mentionBg = colors.getValue("mentionFill").compositeOver(colors.getValue(surface))
                        assertTrue("$tag mentionText@$surface", contrast(colors.getValue("mentionText"), mentionBg) >= 4.5f)
                        val mentionYouBg = colors.getValue("mentionYouFill").compositeOver(colors.getValue(surface))
                        assertTrue("$tag mentionYouText@$surface", contrast(colors.getValue("mentionYouText"), mentionYouBg) >= 4.5f)
                    }
                    val tabBg = colors.getValue("accentTint").compositeOver(colors.getValue("glass").compositeOver(colors.getValue("canvas")))
                    assertTrue("$tag accent/tabPill", contrast(colors.getValue("accent"), tabBg) >= 4.5f)
                    for (surface in listOf("canvas", "raised", "overlay", "wallpaper", "bubbleIn")) {
                        assertTrue("$tag destructive/$surface", contrast(colors.getValue("destructive"), colors.getValue(surface)) >= 4.5f)
                    }
                    for (surface in listOf("canvas", "raised", "bubbleIn")) {
                        assertTrue("$tag warning/$surface", contrast(colors.getValue("warning"), colors.getValue(surface)) >= 4.5f)
                    }
                    val chipBg = colors.getValue("dateChip").compositeOver(colors.getValue("wallpaper"))
                    assertTrue("$tag onDateChip/dateChip", contrast(colors.getValue("onDateChip"), chipBg) >= 4.5f)
                    val meta = colors.getValue("bubbleOutMeta").compositeOver(colors.getValue("accentFill"))
                    assertTrue("$tag bubbleOutMeta/accentFill", contrast(meta, colors.getValue("accentFill")) >= 4.5f)

                    if (highContrast) {
                        assertTrue("$tag border contrast strengthens",
                            contrast(colors.getValue("border"), colors.getValue("canvas")) > contrast(normal.getValue("border"), normal.getValue("canvas")))
                        assertTrue("$tag textSecondary contrast strengthens",
                            contrast(colors.getValue("textSecondary"), colors.getValue("canvas")) > contrast(normal.getValue("textSecondary"), normal.getValue("canvas")))
                        if (dark) {
                            assertEquals("$tag dark high-contrast uses pure black canvas", Color.Black.toArgb(), colors.getValue("canvas").toArgb())
                        }
                    }
                }
            }
            val darkNormal = themeRoles(theme, dark = true, increaseContrast = false)
            val elevation = listOf("sunken", "canvas", "raised", "overlay").map { darkNormal.getValue(it).luminance() }
            assertTrue("${theme.key} dark surfaces step upward: $elevation", elevation.zipWithNext().all { (a, b) -> a < b })

            val darkHighContrast = themeRoles(theme, dark = true, increaseContrast = true)
            val hcElevation = listOf("canvas", "raised", "overlay").map { darkHighContrast.getValue(it).luminance() }
            assertTrue("${theme.key} dark high-contrast surfaces step upward: $hcElevation", hcElevation.zipWithNext().all { (a, b) -> a < b })
        }
    }

    private fun contrast(first: Color, second: Color): Float {
        val (dark, light) = listOf(first.luminance(), second.luminance()).sorted()
        return (light + 0.05f) / (dark + 0.05f)
    }

    private fun color(value: JsonElement): Color {
        val parts = value.asString.removePrefix("#").split('/')
        return Color(0xff000000 or parts[0].toLong(16)).copy(alpha = parts.getOrNull(1)?.toFloat() ?: 1f)
    }
}
