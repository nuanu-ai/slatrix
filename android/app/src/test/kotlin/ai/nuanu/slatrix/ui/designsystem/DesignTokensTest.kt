package ai.nuanu.slatrix.ui.designsystem

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.google.gson.JsonElement
import com.google.gson.JsonParser
import java.io.File
import org.junit.Assert.assertEquals
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

    private fun color(value: JsonElement): Color {
        val parts = value.asString.removePrefix("#").split('/')
        return Color(0xff000000 or parts[0].toLong(16)).copy(alpha = parts.getOrNull(1)?.toFloat() ?: 1f)
    }
}
