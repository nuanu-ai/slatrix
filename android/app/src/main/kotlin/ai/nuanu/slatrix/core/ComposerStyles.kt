package ai.nuanu.slatrix.core

/**
 * Formatting over `start until end` of the composer's text. A block kind formats whole lines: a line has it when its
 * first character does, and an empty line when the line break before it does.
 */
data class ComposerStyle(val start: Int, val end: Int, val kind: Kind, val href: String? = null) {
    enum class Kind(val block: Boolean = false) {
        Bold, Italic, Strike, Underline, Code, Link, Bullet(true), Numbered(true), Quote(true), CodeBlock(true)
    }
}

/** Formats chosen at the caret for what is typed there next. */
data class ComposerTyping(val position: Int, val kinds: Set<ComposerStyle.Kind>)

internal object ComposerStyles {
    fun lineStart(text: String, position: Int) = text.lastIndexOf('\n', position - 1) + 1
    fun lineEnd(text: String, position: Int) = text.indexOf('\n', position).let { if (it < 0) text.length else it }

    /** The block of the line starting at [start]. */
    fun blockOf(styles: List<ComposerStyle>, text: String, start: Int): ComposerStyle.Kind? {
        val empty = lineEnd(text, start) == start
        return styles.firstOrNull { it.kind.block && if (empty) it.start < start && start <= it.end else it.start <= start && start < it.end }?.kind
    }

    /** What typing at [position] takes: the formats of the character before it, links aside, and its line's block. */
    fun typingAt(styles: List<ComposerStyle>, text: String, position: Int): Set<ComposerStyle.Kind> =
        styles.filter { !it.kind.block && it.kind != ComposerStyle.Kind.Link && it.start < position && position <= it.end }
            .mapTo(mutableSetOf()) { it.kind } + listOfNotNull(blockOf(styles, text, lineStart(text, position)))

    /** What typing at [position] takes, with the formats chosen there at the caret first. */
    fun typing(styles: List<ComposerStyle>, typing: ComposerTyping?, text: String, position: Int): Set<ComposerStyle.Kind> =
        typing?.takeIf { it.position == position }?.kinds ?: typingAt(styles, text, position)

    /**
     * The block that Return on its empty line, or Backspace at its line's start, leaves instead of changing the text,
     * as on the Mac; [caret] is where the change was made.
     */
    fun blockLeft(styles: List<ComposerStyle>, typing: ComposerTyping?, old: String, new: String, caret: Int): ComposerStyle.Kind? {
        if (caret !in 0..old.length) return null
        val returned = new == old.substring(0, caret) + "\n" + old.substring(caret)
        val emptyLine = lineStart(old, caret) == caret && lineEnd(old, caret) == caret
        if (returned && emptyLine) return typing(styles, typing, old, caret).firstOrNull { it.block }
        val backspaced = caret > 0 && old[caret - 1] == '\n' && new == old.removeRange(caret - 1, caret)
        return if (backspaced) blockOf(styles, old, caret) else null
    }

    /** The formats once the text went from [old] to [new]; what was typed takes [typing], or the formats before it. */
    fun after(styles: List<ComposerStyle>, old: String, new: String, typing: ComposerTyping?): List<ComposerStyle> {
        val prefix = old.commonPrefixWith(new).length
        val suffix = old.substring(prefix).commonSuffixWith(new.substring(prefix)).length
        val changedEnd = old.length - suffix
        val insertedEnd = new.length - suffix
        val shift = new.length - old.length
        fun start(x: Int) = when { x < prefix -> x; x >= changedEnd -> x + shift; else -> insertedEnd }
        fun end(x: Int) = when { x <= prefix -> x; x >= changedEnd -> x + shift; else -> prefix }
        var moved = styles.map { it.copy(start = start(it.start), end = end(it.end)) }
        if (insertedEnd > prefix) {
            val kinds = typing(styles, typing, old, prefix)
            moved = cut(moved, prefix, insertedEnd) { it != ComposerStyle.Kind.Link } +
                kinds.map { ComposerStyle(prefix, insertedEnd, it) }
        }
        return normalized(moved)
    }

    /** Slack's toggle: on for the whole selection unless all of it has it already; a block on every line it touches. */
    fun toggled(styles: List<ComposerStyle>, text: String, start: Int, end: Int, kind: ComposerStyle.Kind, href: String?): List<ComposerStyle> {
        if (kind == ComposerStyle.Kind.Link) {
            val unlinked = cut(styles, start, end) { it == kind }
            return normalized(if (href.isNullOrBlank()) unlinked else unlinked + ComposerStyle(start, end, kind, href))
        }
        if (!kind.block) {
            val on = (start until end).any { at -> text[at] != '\n' && styles.none { it.kind == kind && it.start <= at && at < it.end } }
            val off = cut(styles, start, end) { it == kind }
            return normalized(if (on) off + ComposerStyle(start, end, kind) else off)
        }
        val first = lineStart(text, start)
        val last = lineEnd(text, end)
        val starts = generateSequence(first) { lineEnd(text, it).takeIf { e -> e < last }?.plus(1) }.toList()
        val on = starts.any { blockOf(styles, text, it) != kind }
        // The break before the first line too, so an empty first line has it.
        val off = cut(styles, (first - 1).coerceAtLeast(0), last) { it.block }
        return normalized(if (on) off + ComposerStyle((first - 1).coerceAtLeast(0), last, kind) else off)
    }

    private fun cut(styles: List<ComposerStyle>, start: Int, end: Int, kinds: (ComposerStyle.Kind) -> Boolean) = styles.flatMap {
        if (!kinds(it.kind) || it.end <= start || it.start >= end) listOf(it)
        else listOfNotNull(it.copy(end = start).takeIf { s -> s.start < s.end }, it.copy(start = end).takeIf { s -> s.start < s.end })
    }

    /** Sorted, without empty ranges, and with touching ranges of one kind joined. */
    private fun normalized(styles: List<ComposerStyle>): List<ComposerStyle> {
        val result = mutableListOf<ComposerStyle>()
        for (style in styles.filter { it.start < it.end }.sortedWith(compareBy({ it.kind }, { it.href }, { it.start }))) {
            val previous = result.lastOrNull()
            if (previous != null && previous.kind == style.kind && previous.href == style.href && style.start <= previous.end)
                result[result.lastIndex] = previous.copy(end = maxOf(previous.end, style.end))
            else result += style
        }
        return result.sortedWith(compareBy({ it.start }, { it.kind }))
    }
}
