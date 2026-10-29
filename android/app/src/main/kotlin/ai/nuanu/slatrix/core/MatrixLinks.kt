package ai.nuanu.slatrix.core

import java.io.ByteArrayOutputStream
import java.net.URI
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
}

/** Matrix links in messages, by the rules in spec/matrix-links.json, which the Mac checks around the SDK's parser. */
object MatrixLinks {
    private const val LIMIT = 8_192
    private val serverName = Regex("""(\[[0-9A-Fa-f:.]+]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?""")
    private val sigils = mapOf("u" to "@", "r" to "#", "roomid" to "!")

    /** A link that opens in the app or is refused, rather than going to the browser; a look-alike host isn't one. */
    fun isMatrix(link: String): Boolean {
        val uri = runCatching { URI(link) }.getOrNull()
            ?: return link.startsWith("matrix:", ignoreCase = true) || link.startsWith("https://matrix.to/", ignoreCase = true)
        return uri.scheme.equals("matrix", ignoreCase = true) || uri.host.equals("matrix.to", ignoreCase = true)
    }

    /** Where [link] points, or null when it isn't a Matrix link or is malformed. */
    fun parse(link: String): MatrixLink? {
        if (!isMatrix(link) || !clean(link, LIMIT)) return null
        val uri = runCatching { URI(link) }.getOrNull() ?: return null
        return if (uri.scheme.equals("matrix", ignoreCase = true)) matrixUri(uri) else matrixTo(uri)
    }

    /** The conversation [alias] names on its server, or null when the server doesn't know it. */
    suspend fun roomIdOf(client: Client, alias: String): String? = withContext(Dispatchers.Default) {
        quietly { client.resolveRoomAlias(alias)?.roomId }?.takeIf { it.startsWith("!") && clean(it, 2_048) }
    }

    private fun matrixTo(uri: URI): MatrixLink? {
        if (uri.scheme != "https" || uri.host != "matrix.to" || uri.rawUserInfo != null || uri.port != -1 || uri.rawPath != "/" ||
            uri.rawQuery != null) return null
        val fragment = uri.rawFragment?.takeIf { it.startsWith("/") } ?: return null
        val path = fragment.substringBefore('?')
        // The SDK's parser misreads empty segments, so the Mac refuses them before it; so does this.
        if ("//" in path) return null
        val segments = path.drop(1).split('/')
        if (segments.size > 2) return null
        val id = decode(segments[0]) ?: return null
        val event = segments.getOrNull(1)?.let { decode(it) ?: return null }
        val via = query(fragment.substringAfter('?', ""), actions = false) ?: return null
        return link(id, event, via)
    }

    private fun matrixUri(uri: URI): MatrixLink? {
        if (!uri.isOpaque || uri.rawFragment != null) return null
        val part = uri.rawSchemeSpecificPart
        val segments = part.substringBefore('?').split('/')
        val sigil = sigils[segments[0]] ?: return null
        val event = when (segments.size) {
            2 -> null
            4 -> if (segments[2] == "e" && sigil != "@") decode(segments[3])?.let { "$$it" } ?: return null else return null
            else -> return null
        }
        val id = decode(segments[1])?.let { sigil + it } ?: return null
        val via = query(part.substringAfter('?', ""), actions = true) ?: return null
        return link(id, event, via)
    }

    private fun link(id: String, event: String?, via: List<String>): MatrixLink? {
        if (event != null && (!event.startsWith("$") || event.length < 2)) return null
        val target = when (id.first()) {
            '@' -> MatrixLink.Target.User(id).takeIf { event == null && named(id) }
            '!' -> MatrixLink.Target.Room(id, event).takeIf { named(id) }
            '#' -> MatrixLink.Target.Alias(id, event).takeIf { named(id) }
            else -> null
        }
        return target?.let { MatrixLink(it, via) }
    }

    /** A sigil, a name and a server, as user IDs, aliases and the room IDs links carry are written. */
    private fun named(id: String): Boolean {
        val colon = id.indexOf(':')
        return colon > 1 && serverName.matches(id.substring(colon + 1))
    }

    /** The via hints, in order; a matrix: URI may also ask to join or chat. Anything else refuses the link. */
    private fun query(query: String, actions: Boolean): List<String>? {
        if (query.isEmpty()) return emptyList()
        val via = mutableListOf<String>()
        for (pair in query.split('&')) {
            val key = pair.substringBefore('=')
            val value = decode(pair.substringAfter('=', "")) ?: return null
            when {
                key == "via" && serverName.matches(value) -> via += value
                key == "action" && actions && value in setOf("join", "chat") -> Unit
                else -> return null
            }
        }
        return via.takeIf { it.size <= 32 }
    }

    /** Percent-decodes once, as UTF-8, or null when the result isn't a clean ID. */
    private fun decode(raw: String): String? {
        val bytes = ByteArrayOutputStream()
        var index = 0
        while (index < raw.length) {
            val char = raw[index]
            if (char == '%') {
                val hex = raw.substring(index + 1, minOf(index + 3, raw.length))
                if (hex.length != 2 || hex.any { Character.digit(it, 16) < 0 }) return null
                bytes.write(hex.toInt(16))
                index += 3
            } else {
                bytes.write(char.toString().toByteArray())
                index++
            }
        }
        return bytes.toString(Charsets.UTF_8.name()).takeIf { clean(it, 2_048) }
    }

    /** Not empty, within [limit] UTF-8 bytes, and free of control and format characters, as the Mac checks. */
    private fun clean(value: String, limit: Int) = value.isNotEmpty() && value.toByteArray().size <= limit &&
        value.none { Character.getType(it) == Character.CONTROL.toInt() || Character.getType(it) == Character.FORMAT.toInt() }
}
