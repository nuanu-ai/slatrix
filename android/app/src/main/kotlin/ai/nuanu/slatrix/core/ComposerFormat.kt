package ai.nuanu.slatrix.core

import java.net.URI
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode

/** The composer's text with its pills and formats. */
data class ComposerContent(val text: String, val mentions: List<ComposerMention>, val styles: List<ComposerStyle> = emptyList())

data class ComposerMessage(val body: String, val html: String?, val mentions: List<String>, val mentionsRoom: Boolean,
    val target: ComposerTarget? = null)

object ComposerFormat {
    private const val userPattern = "@[A-Za-z0-9._=/+\\-]+:(?:\\[[0-9A-Fa-f:]+\\]|[A-Za-z0-9](?:[A-Za-z0-9.\\-]*[A-Za-z0-9])?)(?::[0-9]{1,5})?"
    private val userID = Regex("^$userPattern$")
    internal val mentioned = Regex("(?<![A-Za-z0-9_])(?:$userPattern|@room(?![A-Za-z0-9_:]))")

    /**
     * The composer's text as a draft: Matrix HTML from the spec's list, with each pill in [mentions] a link to its person
     * and [styles] as tags. Lines in one block share a list, quote or code block.
     */
    fun draft(text: String, mentions: List<ComposerMention> = emptyList(), styles: List<ComposerStyle> = emptyList()): String {
        val starts = generateSequence(0) { start -> text.indexOf('\n', start).takeIf { it >= 0 }?.plus(1) }.toList()
        val lines = starts.map { it to ComposerStyles.lineEnd(text, it) }
        val blocks = starts.map { ComposerStyles.blockOf(styles, text, it) }
        val html = StringBuilder()
        var index = 0
        while (index < lines.size) {
            val block = blocks[index]
            var next = index
            while (next < lines.size && blocks[next] == block) next++
            val group = lines.subList(index, next)
            when (block) {
                null -> {
                    html.append(group.joinToString("<br>") { (start, end) -> inline(text, start, end, mentions, styles) })
                    // A break before a block shows nothing, so an empty last line needs one more.
                    if (next < lines.size && group.last().let { it.first == it.second }) html.append("<br>")
                }
                ComposerStyle.Kind.Quote -> html.append("<blockquote>")
                    .append(group.joinToString("<br>") { (start, end) -> inline(text, start, end, mentions, styles) }).append("</blockquote>")
                ComposerStyle.Kind.CodeBlock -> html.append("<pre><code>")
                    .append(escape(text.substring(group.first().first, group.last().second))).append("</code></pre>")
                else -> {
                    val tag = if (block == ComposerStyle.Kind.Numbered) "ol" else "ul"
                    html.append("<$tag>").append(group.joinToString("") { (start, end) -> "<li>${inline(text, start, end, mentions, styles)}</li>" })
                        .append("</$tag>")
                }
            }
            index = next
        }
        return html.toString()
    }

    /** One line's text, its formats as tags. HTML collapses spaces, so leading and repeated ones go as no-break spaces. */
    private fun inline(text: String, start: Int, end: Int, mentions: List<ComposerMention>, styles: List<ComposerStyle>): String {
        val inline = styles.filter { !it.kind.block && it.start < end && it.end > start }
        val pills = mentions.filter { it.start >= start && it.end <= end }
        val cuts = (listOf(start, end) + (inline.flatMap { listOf(it.start, it.end) } + pills.flatMap { listOf(it.start, it.end) })
            .filter { it in start..end }).distinct().sorted()
        val html = StringBuilder()
        for ((from, to) in cuts.zipWithNext()) {
            val pill = pills.firstOrNull { it.start == from }
            if (pills.any { it.start < from && from < it.end }) continue
            val on = inline.filter { it.start <= from && to <= it.end }
            var piece = if (pill != null) "<a href=\"${escape(permalink(pill.userId))}\">${escape(text.substring(pill.start + 1, pill.end))}</a>"
            else buildString {
                for (at in from until to) append(if (text[at] == ' ' && (at == start || text[at - 1] == ' ')) "&nbsp;" else escape(text[at].toString()))
            }
            val kinds = on.map { it.kind }
            if (pill == null && ComposerStyle.Kind.Code in kinds) piece = "<code>$piece</code>"
            for ((kind, tag) in listOf(ComposerStyle.Kind.Strike to "del", ComposerStyle.Kind.Italic to "em", ComposerStyle.Kind.Bold to "strong"))
                if (kind in kinds) piece = "<$tag>$piece</$tag>"
            on.firstOrNull { it.kind == ComposerStyle.Kind.Link }?.href?.takeIf { pill == null }?.let { piece = "<a href=\"${escape(it)}\">$piece</a>" }
            html.append(piece)
        }
        return html.toString()
    }

    /** What a draft this composer wrote, or a message being edited, holds as the composer's text, pills and formats. */
    fun editable(draftHtml: String): ComposerContent {
        val text = StringBuilder()
        val mentions = mutableListOf<ComposerMention>()
        val styles = mutableListOf<ComposerStyle>()
        var breakPending = false
        fun mark(start: Int, kinds: Set<ComposerStyle.Kind>, href: String?) {
            kinds.forEach { styles += ComposerStyle(start, text.length, it) }
            if (href != null) styles += ComposerStyle(start, text.length, ComposerStyle.Kind.Link, href)
        }
        fun append(value: String, kinds: Set<ComposerStyle.Kind>, href: String?) {
            if (value.isEmpty()) return
            if (breakPending) { text.append('\n'); breakPending = false }
            val start = text.length
            text.append(value)
            mark(start, kinds, href)
        }
        /** A new line inside [block] keeps it, so an empty line there still has it. */
        fun lineBreak(block: ComposerStyle.Kind?) {
            breakPending = false
            text.append('\n')
            if (block != null) styles += ComposerStyle(text.length - 1, text.length, block)
        }
        fun startBlock() { if (text.isNotEmpty() && !text.endsWith('\n')) breakPending = true }
        fun walk(element: Element, kinds: Set<ComposerStyle.Kind>, href: String?) {
            val block = kinds.firstOrNull { it.block }
            for (node in element.childNodes()) when {
                node is TextNode -> append(node.wholeText.replace(' ', ' '), kinds, href)
                node !is Element -> Unit
                node.normalName() == "br" -> lineBreak(block)
                node.normalName() == "a" && mentionedUser(node.attr("href")) != null -> {
                    append("@" + node.wholeText().removePrefix("@"), kinds, null)
                    mentions += ComposerMention(text.length - node.wholeText().removePrefix("@").length - 1, text.length, mentionedUser(node.attr("href"))!!)
                }
                node.normalName() == "a" -> walk(node, kinds, safeLink(node.attr("href")) ?: href)
                node.normalName() == "pre" -> {
                    startBlock()
                    val code = node.wholeText()
                    append(code, kinds - kinds.filter { it.block }.toSet() + ComposerStyle.Kind.CodeBlock, null)
                    breakPending = true
                }
                node.normalName() in setOf("ul", "ol", "blockquote") -> {
                    startBlock()
                    val kind = when (node.normalName()) {
                        "ul" -> ComposerStyle.Kind.Bullet
                        "ol" -> ComposerStyle.Kind.Numbered
                        else -> ComposerStyle.Kind.Quote
                    }
                    val inner = kinds.filterNot { it.block }.toSet() + kind
                    if (kind == ComposerStyle.Kind.Quote) walk(node, inner, href)
                    else node.children().filter { it.normalName() == "li" }.forEachIndexed { index, item ->
                        if (index > 0) lineBreak(kind)
                        walk(item, inner, href)
                    }
                    breakPending = true
                }
                else -> {
                    val kind = when (node.normalName()) {
                        "b", "strong" -> ComposerStyle.Kind.Bold
                        "i", "em" -> ComposerStyle.Kind.Italic
                        "s", "strike", "del" -> ComposerStyle.Kind.Strike
                        "code", "tt" -> ComposerStyle.Kind.Code
                        else -> null
                    }
                    if (kind == null && node.isBlock) startBlock()
                    walk(node, kinds + listOfNotNull(kind), href)
                    if (kind == null && node.isBlock) breakPending = true
                }
            }
        }
        walk(Jsoup.parseBodyFragment(draftHtml).body(), emptySet(), null)
        return ComposerContent(text.toString(), mentions, styles.filter { it.start < it.end })
    }

    fun message(draftHtml: String): ComposerMessage {
        val root = Jsoup.parseBodyFragment(draftHtml).body()
        mergeMentions(root)
        val renderer = Renderer()
        val result = renderer.children(root)
        return ComposerMessage(
            result.body.trim(' ', '\n', '\r').replace('\u00a0', ' '),
            result.html.trim().takeIf { renderer.formatted },
            renderer.mentions.sorted(),
            renderer.mentionsRoom,
        )
    }

    private data class Fragment(val body: String, val html: String)

    private class Renderer {
        val mentions = mutableSetOf<String>()
        var mentionsRoom = false
        var formatted = false

        fun children(element: Element, literal: Boolean = false): Fragment {
            val pieces = element.childNodes().map { render(it, literal) }
            return Fragment(pieces.joinToString("") { it.body }, pieces.joinToString("") { it.html })
        }

        private fun render(node: Node, literal: Boolean): Fragment {
            if (node is TextNode) return text(node.wholeText, literal)
            if (node !is Element) return Fragment("", "")
            val tag = node.normalName()
            if (tag in setOf("script", "style", "iframe", "object", "embed", "svg", "math")) return Fragment("", "")
            if (tag == "br") return Fragment("\n", "<br>")
            if (tag == "pre") {
                formatted = true
                val code = node.wholeText()
                return Fragment("\n```\n$code\n```\n", "<pre><code>${escape(code)}</code></pre>")
            }
            if (tag == "a") {
                val href = safeLink(node.attr("href"))
                val id = href?.let(::mentionedUser)
                if (!literal && id != null) {
                    formatted = true
                    mentions += id
                    val label = node.wholeText().trim().let { if (it.isEmpty() || it == id) localpart(id) else it.trimStart('@') }
                    return Fragment("@$label", "<a href=\"${escape(permalink(id))}\">${escape(label)}</a>")
                }
                val inner = children(node, literal = true)
                if (href == null) return inner
                formatted = true
                return Fragment(
                    if (inner.body == href) inner.body else "${inner.body} ($href)",
                    "<a href=\"${escape(href)}\">${inner.html}</a>",
                )
            }
            if (tag == "ul" || tag == "ol") {
                formatted = true
                val items = node.children().filter { it.normalName() == "li" }.map { children(it, literal) }
                return Fragment(
                    "\n" + items.mapIndexed { index, item -> (if (tag == "ol") "${index + 1}. " else "- ") + item.body.trim('\n') }.joinToString("\n") + "\n",
                    "<$tag>" + items.joinToString("") { "<li>${it.html}</li>" } + "</$tag>",
                )
            }
            val inner = children(node, literal || tag == "code" || tag == "tt")
            if (tag == "blockquote") {
                formatted = true
                return Fragment("\n" + inner.body.trim('\n').lines().joinToString("\n") { "> $it" } + "\n", "<blockquote>${inner.html}</blockquote>")
            }
            val inlineTag = when (tag) {
                "b", "strong" -> "strong"
                "i", "em" -> "em"
                "s", "strike", "del" -> "del"
                "u" -> "u"
                "code", "tt" -> "code"
                else -> null
            }
            if (inlineTag != null) {
                formatted = true
                return Fragment(if (inlineTag == "code") "`${inner.body}`" else inner.body, "<$inlineTag>${inner.html}</$inlineTag>")
            }
            return if (tag == "p" || tag == "div") Fragment("\n${inner.body}\n", "${inner.html}<br>") else inner
        }

        private fun text(plain: String, literal: Boolean): Fragment {
            if (literal) return Fragment(plain, escape(plain))
            val body = StringBuilder()
            val html = StringBuilder()
            var cursor = 0
            for (match in mentioned.findAll(plain)) {
                val before = plain.substring(cursor, match.range.first)
                body.append(before)
                html.append(escape(before))
                val id = match.value
                if (id == "@room") {
                    mentionsRoom = true
                    body.append(id)
                    html.append(id)
                } else {
                    mentions += id
                    formatted = true
                    val label = localpart(id)
                    body.append("@$label")
                    html.append("<a href=\"${escape(permalink(id))}\">${escape(label)}</a>")
                }
                cursor = match.range.last + 1
            }
            body.append(plain.substring(cursor))
            html.append(escape(plain.substring(cursor)))
            return Fragment(body.toString(), html.toString())
        }
    }

    private fun mergeMentions(element: Element) {
        for (child in element.children().toList()) {
            mergeMentions(child)
            val previous = child.previousSibling() as? Element ?: continue
            val id = if (child.normalName() == "a") mentionedUser(child.attr("href")) else null
            if (id != null && previous.normalName() == "a" && mentionedUser(previous.attr("href")) == id) {
                previous.appendText(child.wholeText())
                child.remove()
            }
        }
    }

    internal fun mentionedUser(link: String): String? {
        val uri = runCatching { URI(link) }.getOrNull() ?: return null
        val id = when {
            uri.scheme == "https" && uri.host.equals("matrix.to", ignoreCase = true) -> uri.fragment?.takeIf { it.startsWith("/@") }?.drop(1)?.substringBefore('?')
            uri.scheme == "matrix" && uri.schemeSpecificPart.startsWith("u/") -> "@" + uri.schemeSpecificPart.drop(2).substringBefore('?')
            else -> null
        }
        return id?.takeIf { userID.matches(it) }
    }

    private fun safeLink(link: String): String? = runCatching { URI(link) }.getOrNull()
        ?.takeIf { it.scheme?.lowercase() in setOf("https", "http", "mailto", "matrix") }?.toString()

    internal fun localpart(id: String) = id.drop(1).substringBefore(':')
    internal fun permalink(id: String) = "https://matrix.to/#/$id"
    private fun escape(text: String): String = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("\u00a0", "&nbsp;")
}
