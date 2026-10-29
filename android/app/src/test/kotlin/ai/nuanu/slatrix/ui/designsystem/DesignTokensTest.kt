package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.google.gson.JsonElement
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class DesignTokensTest {
    @Test fun `every theme and palette matches the shared token contract`() {
        val spec = JsonParser.parseString(File(System.getProperty("slatrix.root"), "design/tokens.json").readText()).asJsonObject
        assertEquals(spec["palettes"].asJsonArray.map { it.asString }, SidebarPalette.entries.map { it.tokenName })
        for (dark in listOf(false, true)) {
            for (palette in SidebarPalette.entries) {
                val expected = spec["colors"].asJsonObject.entrySet().associate { (role, value) ->
                    var leaf = value
                    if (leaf.isJsonObject) leaf = leaf.asJsonObject[if (dark) "dark" else "light"]
                    if (leaf.isJsonObject) leaf = leaf.asJsonObject[palette.tokenName]
                    role to color(leaf).toArgb()
                }
                assertEquals("dark=$dark palette=$palette", expected, DesignTokens.colors(dark, palette).mapValues { it.value.toArgb() })
            }
        }
        assertEquals(spec["fileColors"].asJsonObject.entrySet().associate { it.key to color(it.value).toArgb() }, DesignTokens.fileColors.mapValues { it.value.toArgb() })
        assertEquals(spec["avatarColors"].asJsonArray.map { color(it).toArgb() }, DesignTokens.avatarColors.map { it.toArgb() })
        assertEquals(spec["radius"].asJsonObject.entrySet().associate { it.key to it.value.asInt }, DesignTokens.radii)
    }

    private fun color(value: JsonElement): Color {
        val parts = value.asString.removePrefix("#").split('/')
        return Color(0xff000000 or parts[0].toLong(16)).copy(alpha = parts.getOrNull(1)?.toFloat() ?: 1f)
    }
}
