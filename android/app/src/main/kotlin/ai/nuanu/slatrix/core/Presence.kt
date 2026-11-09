package ai.nuanu.slatrix.core

import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.matrix.rustcomponents.sdk.Client

/** A green dot when active, a hollow ring when away; nothing when unknown. */
enum class Presence { Active, Away }

/**
 * The dot on a person's picture, from the presence the server reports. A server with presence turned off reports even
 * you as offline while you're connected, so then nobody gets a dot.
 */
object PresencePolicy {
    /** [own] and [theirs] are Matrix presence states, null when the server didn't answer. */
    fun dot(own: String?, theirs: String?): Presence? = when {
        !shared(own) -> null
        theirs == "online" -> Presence.Active
        theirs == "unavailable" || theirs == "offline" -> Presence.Away
        else -> null
    }

    fun shared(own: String?): Boolean = own == "online" || own == "unavailable"

    /** Each of [people]'s dot, asking [fetch] for their presence state; empty when the server doesn't share presence. */
    suspend fun dots(me: String, people: List<String>, fetch: suspend (String) -> String?): Map<String, Presence> {
        val own = fetch(me)
        if (!shared(own)) return emptyMap()
        return people.mapNotNull { person -> dot(own, fetch(person))?.let { person to it } }.toMap()
    }
}

/** The SDK can't read presence, so this asks the server directly, with the session's own token. */
internal suspend fun serverPresence(client: Client, userId: String): String? = withContext(Dispatchers.IO) {
    runCatching {
        val session = client.session()
        val path = "/_matrix/client/v3/presence/" + URLEncoder.encode(userId, "UTF-8").replace("+", "%20") + "/status"
        val connection = URI(session.homeserverUrl.trimEnd('/') + path).toURL().openConnection() as HttpURLConnection
        try {
            connection.setRequestProperty("Authorization", "Bearer ${session.accessToken}")
            if (connection.responseCode != 200) null
            else JSONObject(connection.inputStream.bufferedReader().readText()).optString("presence").ifEmpty { null }
        } finally {
            connection.disconnect()
        }
    }.getOrNull()
}
