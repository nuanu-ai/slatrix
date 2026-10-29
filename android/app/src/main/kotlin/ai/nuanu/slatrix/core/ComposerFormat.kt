package ai.nuanu.slatrix.core

import java.net.URI
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode

data class ComposerMessage(val body: String, val html: String?, val mentions: List<String>, val mentionsRoom: Boolean)

object ComposerFormat {
    private const val userPattern = "@[A-Za-z0-9._=/+\\-]+:(?:\\[[0-9A-Fa-f:]+\\]|[A-Za-z0-9](?:[A-Za-z0-9.\\-]*[A-Za-z0-9])?)(?::[0-9]{1,5})?"
    private val userID = Regex("^$userPattern$")
    private val mentioned = Regex("(?<![A-Za-z0-9_])(?:$userPattern|@room(?![A-Za-z0-9_:]))")

    fun plainTextDraft(text: String): String = text.replace("\r\n", "\n").replace("\r", "\n").split('\n').joinToString("<br>") { line ->
        line.mapIndexed { index, character ->
            if (character == ' ' && (index == 0 || line[index - 1] == ' ')) "&nbsp;" else escape(character.toString())
        }.joinToString("")
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

    private fun mentionedUser(link: String): String? {
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

    private fun localpart(id: String) = id.drop(1).substringBefore(':')
    private fun permalink(id: String) = "https://matrix.to/#/$id"
    private fun escape(text: String): String = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("\u00a0", "&nbsp;")
}
