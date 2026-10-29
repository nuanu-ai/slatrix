package ai.nuanu.slatrix.core

import android.content.Context
import android.graphics.Paint

enum class EmojiCategory(val title: String) {
    Smileys("Smileys & emotion"), People("People & body"), Nature("Animals & nature"), Food("Food & drink"),
    Activities("Activities"), Travel("Travel & places"), Objects("Objects"), Symbols("Symbols"), Flags("Flags"),
}

/** One emoji the picker offers: what it inserts, where it sits and what Slack calls it, its own shortcode first. */
data class Emoji(val value: String, val category: EmojiCategory, val shortcodes: List<String>, val name: String)

/** The Mac's catalog, read from its `EmojiData.swift`, which the build packs as the `emoji.txt` asset. */
class EmojiCatalog private constructor(val all: List<Emoji>) {
    // Reversed, so the first emoji with a key keeps it.
    private val byKey = all.asReversed().associateBy { key(it.value) }

    fun emoji(value: String): Emoji? = byKey[key(value)]

    /** `:+1:`, `:+1::skin-tone-4:` for a toned one, as Slack writes them; anything else as it is. */
    fun shortcode(value: String): String {
        val code = emoji(value)?.shortcodes?.firstOrNull() ?: return value
        // Slack numbers the five tones 2 through 6.
        val tone = value.codePoints().toArray().firstOrNull { it in TONES }?.let { ":skin-tone-${it - 0x1F3FA + 1}:" }.orEmpty()
        return ":$code:$tone"
    }

    /**
     * Exact shortcodes first, then shortcodes the query starts, then words that start with it, then anything that
     * contains it; picker order within each.
     */
    fun search(query: String): List<Emoji> {
        val code = query.trim(' ', '\t', ':').lowercase()
        if (code.isEmpty()) return emptyList()
        val words = code.replace('_', ' ')
        val tiers = List(4) { mutableListOf<Emoji>() }
        for (emoji in all) {
            val codes = emoji.shortcodes
            when {
                code in codes -> tiers[0] += emoji
                codes.any { it.startsWith(code) } -> tiers[1] += emoji
                emoji.name.startsWith(words) || emoji.name.contains(" $words") ||
                    codes.any { it.contains("_$code") || it.contains("-$code") } -> tiers[2] += emoji
                emoji.name.contains(words) || codes.any { it.contains(code) } -> tiers[3] += emoji
            }
        }
        return tiers.flatten()
    }

    companion object {
        private val TONES = 0x1F3FB..0x1F3FF
        /** A Swift string's line continuation, which joins a long name to its next line. */
        private val continuation = Regex("""\\\n\s*""")
        @Volatile private var loaded: EmojiCatalog? = null

        /** Reads the asset once, without the emoji this device can't draw; call it off the main thread. */
        fun load(context: Context): EmojiCatalog = loaded ?: synchronized(this) {
            loaded ?: parse(context.assets.open("emoji.txt").bufferedReader().use { it.readText() }).let { catalog ->
                val paint = Paint()
                EmojiCatalog(catalog.all.filter { paint.hasGlyph(it.value) })
            }.also { loaded = it }
        }

        /** One emoji per line, `emoji;category;shortcodes;name[;toned]`; the Swift around the lines is skipped. */
        fun parse(source: String) = EmojiCatalog(source.replace(continuation, "").lineSequence().mapNotNull { line ->
            val fields = line.trim().split(';')
            val category = fields.getOrNull(1)?.toIntOrNull()?.let(EmojiCategory.entries::getOrNull)
            if (fields.size < 4 || category == null) null
            else Emoji(fields[0], category, fields[2].split(' ').filter(String::isNotEmpty), fields[3])
        }.toList())

        /** Without presentation selectors or skin tones, so a heart sent as U+2764 alone, or a toned thumb, finds its emoji. */
        private fun key(value: String) = buildString {
            value.codePoints().forEach { if (it != 0xFE0F && it !in TONES) appendCodePoint(it) }
        }
    }
}

/** Recently used emoji, newest first, as Element keeps them in `io.element.recent_emoji`. */
object EmojiRecents {
    /** Slack's one-tap reactions before you have used any. */
    private val defaults = listOf("✅", "👀", "🙌", "👍", "🎉")

    fun adding(emoji: String, recent: List<String>): List<String> = listOf(emoji) + recent.filter { it != emoji }

    fun quick(recent: List<String>, count: Int): List<String> = (recent + defaults.filter { it !in recent }).take(count)
}
