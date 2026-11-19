package ai.nuanu.slatrix.core

import java.text.BreakIterator
import java.util.Locale

object AvatarPlaceholder {
    /** The number of shared avatar colors in design/tokens.json; DesignTokensTest checks the colors themselves. */
    private const val ColorCount = 12uL

    fun initials(name: String): String {
        val characters = BreakIterator.getCharacterInstance(Locale.ROOT)
        return name.splitToSequence(Regex("[\\p{javaWhitespace}\\p{Z}._-]+"))
            .mapNotNull { part ->
                characters.setText(part)
                generateSequence(characters.first()) { characters.next().takeIf { it != BreakIterator.DONE } }
                    .zipWithNext()
                    .firstOrNull { (start, _) -> Character.isLetterOrDigit(part.codePointAt(start)) }
                    ?.let { (start, end) -> part.substring(start, end).uppercase(Locale.ROOT) }
            }
            .take(2)
            .joinToString("")
    }

    fun colorIndex(name: String): Int {
        var hash = 5381uL
        for (byte in name.toByteArray(Charsets.UTF_8)) {
            hash = hash * 33uL + (byte.toInt() and 0xff).toULong()
        }
        return (hash % ColorCount).toInt()
    }
}
