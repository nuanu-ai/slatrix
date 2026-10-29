package ai.nuanu.slatrix.core

import java.net.URI
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode

enum class TextStyle { Bold, Italic, Strike, Code, Underline }

/** Where a run sits among a message's blocks, which the row indents and decorates. */
data class MessageBlock(val quote: Int = 0, val list: Int = 0, val code: Boolean = false)

data class MessageRun(
    val text: String,
    val styles: Set<TextStyle> = emptySet(),
    val link: String? = null,
    /** The user ID a mention names, or "@room". */
    val mention: String? = null,
    val block: MessageBlock = MessageBlock(),
    /** A list item's "• " or "3. ". */
    val marker: Boolean = false,
)

/** Matrix HTML as styled runs, by the rule in spec/message-format.json that the Mac's MessageBodyRenderer follows too. */
object MessageFormat {
    private const val MAX_INPUT_BYTES = 65_536
    private const val MAX_OUTPUT = 65_536
    private const val MAX_NODES = 4_096
    private const val MAX_DEPTH = 50
    private const val SPOILER = "[Spoiler hidden]"
    private val dropped = setOf("script", "style", "iframe", "object", "embed", "link", "meta", "base", "head", "title",
        "form", "input", "button", "textarea", "select", "option", "svg", "video", "audio", "source", "mx-reply")
    private val headings = setOf("h1", "h2", "h3", "h4", "h5", "h6")
    private val containers = headings + setOf("p", "div", "span", "li", "html", "body", "table", "thead", "tbody",
        "tfoot", "tr", "td", "th", "font")
    private val blocks = headings + setOf("p", "div", "pre", "blockquote", "li", "table", "tr")
    private val addresses = Regex(
        "(?i)(?:https?://|www\\.)[^\\s<>\"]*[^\\s<>\".,;:!?)'\\]]|[A-Za-z0-9._%+\\-]+@[A-Za-z0-9\\-]+(?:\\.[A-Za-z0-9\\-]+)*\\.[A-Za-z]{2,}")

    fun render(body: String, html: String?): List<MessageRun> =
        linkified(mentioned(parse(body, html) ?: fallback(body, html)))

    private fun fallback(body: String, html: String?): List<MessageRun> =
        listOf(MessageRun(if (html?.contains("data-mx-spoiler", ignoreCase = true) == true) SPOILER else bounded(body)))

    private fun bounded(body: String): String {
        if (body.length <= MAX_OUTPUT) return body
        val notice = "\n[Message exceeds the display limit]"
        val cut = body.take(MAX_OUTPUT - notice.length)
        return (if (cut.last().isHighSurrogate()) cut.dropLast(1) else cut) + notice
    }

    private class Failure : Exception()

    private fun parse(body: String, html: String?): List<MessageRun>? {
        if (html.isNullOrEmpty() || html.toByteArray().size > MAX_INPUT_BYTES ||
            html.contains("<!doctype", ignoreCase = true) || html.contains("<!entity", ignoreCase = true)) return null
        val builder = Builder()
        try {
            for (child in Jsoup.parseBodyFragment(html).body().childNodes()) builder.walk(child, Context(), 0)
        } catch (_: Failure) {
            return null
        }
        builder.trimEnd()
        return builder.runs.takeUnless { it.isEmpty() && body.isNotEmpty() }?.map { it.run() }
    }

    private data class Context(
        val styles: Set<TextStyle> = emptySet(),
        val link: String? = null,
        val mention: String? = null,
        val block: MessageBlock = MessageBlock(),
        val marker: Boolean = false,
    )

    private class Piece(val text: StringBuilder, val context: Context) {
        fun run() = MessageRun(text.toString(), context.styles, context.link, context.mention, context.block, context.marker)
    }

    private class Builder {
        val runs = mutableListOf<Piece>()
        private var output = 0
        private var visited = 0
        private val last: Char? get() = runs.lastOrNull()?.text?.lastOrNull()

        fun append(value: String, context: Context, literal: Boolean = false) {
            val normalized = StringBuilder()
            var previous = last
            for (character in value) {
                if (!literal && !context.block.code && character in " \n\r\t\u000C") {
                    if (previous != null && previous != ' ' && previous != '\n') { normalized.append(' '); previous = ' ' }
                } else {
                    normalized.append(character)
                    previous = character
                }
            }
            if (normalized.isEmpty()) return
            output += normalized.length
            if (output > MAX_OUTPUT) throw Failure()
            val tail = runs.lastOrNull()
            if (tail != null && !context.marker && !tail.context.marker && tail.context == context) tail.text.append(normalized)
            else runs.add(Piece(normalized, context))
        }

        /** A line break belongs to the line it ends, so a quote's or code block's lines stay one block. */
        fun newline(force: Boolean = false) {
            trimEnd(spacesOnly = true)
            val tail = runs.lastOrNull() ?: return
            if (force || last != '\n') append("\n", Context(block = tail.context.block), literal = true)
        }

        fun trimEnd(spacesOnly: Boolean = false) {
            while (runs.isNotEmpty()) {
                val text = runs.last().text
                while (text.isNotEmpty() && (text.last() == ' ' || !spacesOnly && text.last() in "\n\r")) text.setLength(text.length - 1)
                if (text.isEmpty()) runs.removeAt(runs.lastIndex) else break
            }
        }

        fun walk(node: Node, context: Context, depth: Int) {
            if (depth > MAX_DEPTH || ++visited > MAX_NODES) throw Failure()
            if (node is TextNode) return append(node.wholeText, context)
            if (node !is Element) return
            val name = node.normalName()
            if (name in dropped) return
            if (node.hasAttr("data-mx-maths") || name == "math") throw Failure()
            if (node.hasAttr("data-mx-spoiler")) return append(SPOILER, context)
            var next = context
            when (name) {
                // Google Docs wraps everything it copies in <b style="font-weight:normal">.
                "b", "strong" -> if (!node.attr("style").contains("font-weight:normal")) next = next.styled(TextStyle.Bold)
                "i", "em" -> next = next.styled(TextStyle.Italic)
                "s", "strike", "del" -> next = next.styled(TextStyle.Strike)
                "u" -> next = next.styled(TextStyle.Underline)
                "code", "tt" -> next = next.styled(TextStyle.Code)
                "pre" -> next = next.styled(TextStyle.Code).copy(block = next.block.copy(code = true))
                "a" -> {
                    val link = safeLink(node.attr("href"))
                    val id = link?.let(ComposerFormat::mentionedUser)
                    next = next.copy(link = link, mention = id)
                    if (id != null) {
                        val label = node.wholeText().trim()
                        val shown = if (label.isEmpty() || label == id) ComposerFormat.localpart(id) else label.trimStart('@')
                        // 0.2.8 and 0.2.9 split each mention into two links before its last letter; the second continues it.
                        return append((if (runs.lastOrNull()?.context?.mention == id) "" else "@") + shown, next)
                    }
                }
                "blockquote" -> next = next.copy(block = next.block.copy(quote = next.block.quote + 1))
                "br" -> return newline(force = true)
                "hr" -> { newline(); append("—", context); return newline() }
                "img" -> return node.attr("alt").takeIf { it.isNotEmpty() }?.let { append(it, context) } ?: Unit
                "ul", "ol" -> return list(node, next, depth)
                in containers -> {}
                else -> throw Failure()
            }
            val block = name in blocks
            if (block) newline()
            if (name in headings || name == "th") next = next.styled(TextStyle.Bold)
            for (child in node.childNodes()) walk(child, next, depth + 1)
            if (name == "td" || name == "th") append("\t", Context(), literal = true)
            if (block) newline()
        }

        private fun list(node: Element, context: Context, depth: Int) {
            newline()
            var number = node.attr("start").ifEmpty { "1" }.toIntOrNull() ?: 1
            if (number !in -1_000_000..1_000_000) throw Failure()
            for (item in node.children()) {
                if (item.normalName() != "li") continue
                if (++visited > MAX_NODES || depth + 1 > MAX_DEPTH) throw Failure()
                newline()
                val nested = context.copy(block = context.block.copy(list = context.block.list + 1))
                append(if (node.normalName() == "ol") "$number. " else "• ", Context(block = nested.block, marker = true), literal = true)
                for (child in item.childNodes()) walk(child, nested, depth + 2)
                number++
            }
            newline()
        }

        private fun Context.styled(style: TextStyle) = copy(styles = styles + style)
    }

    fun safeLink(source: String): String? {
        if (source.length > 4_096 || source.any { it.isISOControl() }) return null
        val uri = runCatching { URI(source.trim()) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        if (scheme !in setOf("https", "http", "mailto", "matrix") || uri.rawUserInfo != null) return null
        val valid = if (scheme == "http" || scheme == "https") !uri.host.isNullOrEmpty()
            else !(uri.rawPath ?: uri.rawSchemeSpecificPart).isNullOrEmpty()
        return if (valid) uri.toString() else null
    }

    /** User IDs and @room typed as text become mentions, which read "@localpart". */
    private fun mentioned(runs: List<MessageRun>) = split(runs, ComposerFormat.mentioned, '@') { id, run ->
        if (id == "@room") MessageRun(id, run.styles, mention = id)
        else MessageRun("@" + ComposerFormat.localpart(id), run.styles, ComposerFormat.permalink(id), id)
    }

    /** Web and mail addresses typed as text become links, as in Slack. */
    private fun linkified(runs: List<MessageRun>) = split(runs, addresses, '.') { address, run ->
        val target = when {
            address.contains("://") -> address
            address.startsWith("www.", ignoreCase = true) -> "http://$address"
            else -> "mailto:$address"
        }
        safeLink(target)?.let { MessageRun(address, run.styles, it) }
    }

    private fun split(runs: List<MessageRun>, pattern: Regex, marker: Char, replace: (String, MessageRun) -> MessageRun?) =
        runs.flatMap { run ->
            if (run.link != null || run.mention != null || run.marker || TextStyle.Code in run.styles || marker !in run.text) {
                return@flatMap listOf(run)
            }
            val pieces = mutableListOf<MessageRun>()
            var cursor = 0
            for (match in pattern.findAll(run.text)) {
                val replaced = replace(match.value, run) ?: continue
                if (match.range.first > cursor) pieces += run.copy(text = run.text.substring(cursor, match.range.first))
                pieces += replaced.copy(block = run.block)
                cursor = match.range.last + 1
            }
            if (cursor < run.text.length) pieces += run.copy(text = run.text.substring(cursor))
            pieces
        }
}
