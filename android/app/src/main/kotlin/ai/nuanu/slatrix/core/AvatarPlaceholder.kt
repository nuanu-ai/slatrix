package ai.nuanu.slatrix.core

import java.text.BreakIterator
import java.util.Locale

object AvatarPlaceholder {
    fun initials(name: String): String {
        val characters = BreakIterator.getCharacterInstance(Locale.ROOT)
        return name.trim('@', '#', '!')
            .splitToSequence(Regex("[\\p{javaWhitespace}\\p{Z}._-]+"))
            .filter(String::isNotEmpty)
            .take(2)
            .joinToString("") {
                characters.setText(it)
                it.substring(0, characters.next()).uppercase(Locale.ROOT)
            }
    }

    fun colorIndex(name: String): Int {
        var hash = 5381uL
        for (byte in name.toByteArray(Charsets.UTF_8)) {
            hash = hash * 33uL + (byte.toInt() and 0xff).toULong()
        }
        return (hash % 6uL).toInt()
    }
}
