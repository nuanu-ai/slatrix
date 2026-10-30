package ai.nuanu.slatrix.core

import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client

/** Where a matrix.to link or a matrix: URI points, with its via routing hints. */
data class MatrixLink(val target: Target, val via: List<String> = emptyList()) {
    sealed interface Target {
        data class User(val id: String) : Target
        data class Room(val id: String, val event: String? = null) : Target
        data class Alias(val alias: String, val event: String? = null) : Target
    }

    /** The matrix.to link for this, which a browser can open where a matrix: URI goes nowhere. */
    val web: String get() {
        fun encode(id: String) = id.toByteArray().joinToString("") { byte ->
            val char = byte.toInt().toChar()
            if (byte >= 0 && (char.isLetterOrDigit() || char in "!$@:._-")) char.toString() else "%%%02X".format(byte)
        }
        val (id, event) = when (target) {
            is Target.User -> target.id to null
            is Target.Room -> target.id to target.event
            is Target.Alias -> target.alias to target.event
        }
        return "https://matrix.to/#/" + encode(id) + (event?.let { "/" + encode(it) } ?: "") +
            via.joinToString("&", prefix = if (via.isEmpty()) "" else "?") { "via=" + encode(it) }
    }
}

/** Matrix links in messages, by the rules in spec/matrix-links.json, which the Mac checks around the SDK's parser. */
object MatrixLinks {
    private const val LIMIT = 8_192
    /** A URI's parts, as RFC 3986's appendix B splits any URI: scheme, authority, path, query and fragment. */
    private val parts = Regex("""^(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$""", RegexOption.DOT_MATCHES_ALL)
    private val serverName = Regex("""(\[[0-9A-Fa-f:.]+]|[A-Za-z0-9.-]+)(?::([0-9]{1,5}))?""")
    private val sigils = mapOf("u" to "@", "user" to "@", "r" to "#", "room" to "#", "roomid" to "!")

    /** A link that opens in the app or is refused, rather than going to the browser; a look-alike host isn't one. */
    fun isMatrix(link: String): Boolean {
        val match = parts.matchEntire(link) ?: return false
        val authority = match.groupValues[2]
        return match.groupValues[1].equals("matrix", ignoreCase = true) ||
            authority.substringAfterLast('@').substringBefore(':').equals("matrix.to", ignoreCase = true)
    }

    /** Where [link] points, or null when it isn't a Matrix link or is malformed. */
    fun parse(link: String): MatrixLink? {
        if (!isMatrix(link) || !clean(link, LIMIT)) return null
        val match = checkNotNull(parts.matchEntire(link))
        val (scheme, authority, path, query, fragment) = match.destructured
        val hasAuthority = link.substringAfter(':').startsWith("//")
        val hasQuery = match.groups[4] != null
        val hasFragment = match.groups[5] != null
        return if (scheme.equals("matrix", ignoreCase = true)) {
            if (hasAuthority || hasFragment) null else matrixUri(path, query)
        } else {
            // Nothing but the bare host, path and fragment: no credentials, port or query.
            if (scheme != "https" || authority != "matrix.to" || path != "/" || hasQuery || !hasFragment) null else matrixTo(fragment)
        }
    }

    /** The conversation [alias] names on its server, or null when the server doesn't know it. */
    suspend fun roomIdOf(client: Client, alias: String): String? = withContext(Dispatchers.Default) {
        quietly { client.resolveRoomAlias(alias)?.roomId }?.takeIf { it.startsWith("!") && clean(it, 2_048) }
    }

    private fun matrixTo(fragment: String): MatrixLink? {
        if (!fragment.startsWith("/")) return null
        val path = fragment.substringBefore('?')
        // The SDK's parser misreads empty segments, so the Mac refuses them before it; so does this.
        if ("//" in path) return null
        val segments = path.drop(1).removeSuffix("/").split('/')
        if (segments.size > 2) return null
        val id = decode(segments[0]) ?: return null
        val event = segments.getOrNull(1)?.let { decode(it) ?: return null }
        val via = query(fragment.substringAfter('?', ""), actions = false) ?: return null
        return link(id, event, via)
    }

    private fun matrixUri(path: String, query: String): MatrixLink? {
        val segments = path.removeSuffix("/").split('/')
        val sigil = sigils[segments[0]] ?: return null
        val event = when (segments.size) {
            2 -> null
            4 -> if (segments[2] in setOf("e", "event") && sigil != "@") decode(segments[3])?.let { "$$it" } ?: return null else return null
            else -> return null
        }
        val id = decode(segments[1])?.let { sigil + it } ?: return null
        val via = query(query, actions = true) ?: return null
        return link(id, event, via)
    }

    private fun link(id: String, event: String?, via: List<String>): MatrixLink? {
        if (event != null && (!event.startsWith("$") || event.length < 2)) return null
        val target = when (id.first()) {
            '@' -> MatrixLink.Target.User(id).takeIf { event == null && named(id) }
            // A room ID of room version 12 has no server.
            '!' -> MatrixLink.Target.Room(id, event).takeIf { id.length > 1 && (':' !in id || named(id)) }
            '#' -> MatrixLink.Target.Alias(id, event).takeIf { named(id) }
            else -> null
        }
        return target?.let { MatrixLink(it, via) }
    }

    /** A sigil, a name and a server, as user IDs and aliases are written. */
    private fun named(id: String): Boolean {
        val colon = id.indexOf(':')
        return colon > 1 && server(id.substring(colon + 1))
    }

    /** A host name, an IPv4 address or a bracketed IPv6 one, and a port that fits. */
    private fun server(value: String): Boolean {
        val match = serverName.matchEntire(value) ?: return false
        val host = match.groupValues[1]
        val port = match.groupValues[2]
        if (port.isNotEmpty() && port.toInt() !in 1..65_535) return false
        // A literal address parses without a lookup.
        return !host.startsWith("[") || runCatching { InetAddress.getByName(host) }.isSuccess
    }

    /** The via hints, in order; a matrix: URI may also say what to do, once. Anything else refuses the link. */
    private fun query(query: String, actions: Boolean): List<String>? {
        val via = mutableListOf<String>()
        var action = false
        for (pair in query.split('&').filter { it.isNotEmpty() }) {
            val key = pair.substringBefore('=')
            val value = decode(pair.substringAfter('=', "")) ?: return null
            when {
                key == "via" && server(value) -> via += value
                key == "action" && actions && !action -> action = true
                else -> return null
            }
        }
        return via.takeIf { it.size <= 32 }
    }

    /** Percent-decodes once, as strict UTF-8, or null when the result isn't a clean ID. */
    private fun decode(raw: String): String? {
        val bytes = ByteArrayOutputStream()
        var index = 0
        while (index < raw.length) {
            if (raw[index] == '%') {
                val hex = raw.substring(index + 1, minOf(index + 3, raw.length))
                if (hex.length != 2 || hex.any { Character.digit(it, 16) < 0 }) return null
                bytes.write(hex.toInt(16))
                index += 3
            } else {
                val codePoint = raw.codePointAt(index)
                bytes.write(String(Character.toChars(codePoint)).toByteArray())
                index += Character.charCount(codePoint)
            }
        }
        val decoded = runCatching {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes.toByteArray())).toString()
        }.getOrNull()
        return decoded?.takeIf { clean(it, 2_048) }
    }

    /** Not empty, within [limit] UTF-8 bytes, and free of control and format characters, as the Mac checks. */
    private fun clean(value: String, limit: Int) = value.isNotEmpty() && value.toByteArray().size <= limit &&
        value.codePoints().noneMatch { Character.getType(it) == Character.CONTROL.toInt() || Character.getType(it) == Character.FORMAT.toInt() }
}
