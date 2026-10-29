package ai.nuanu.slatrix.push

import android.content.Context
import android.annotation.SuppressLint
import java.security.MessageDigest
import java.util.Locale
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.matrix.rustcomponents.sdk.Client
import org.matrix.rustcomponents.sdk.HttpPusherData
import org.matrix.rustcomponents.sdk.PushFormat
import org.matrix.rustcomponents.sdk.PusherIdentifiers
import org.matrix.rustcomponents.sdk.PusherKind

@SuppressLint("UseKtx") // KTX edit discards the commit result.
class PushRegistration(context: Context) {
    private val preferences = context.getSharedPreferences("push-registration", Context.MODE_PRIVATE)
    private val appId = context.packageName
    val tokenVersion: Long get() = synchronized(tokenLock) { preferences.getLong("version", 0) }

    fun updateToken(token: String, expectedVersion: Long? = null) = synchronized(tokenLock) {
        require(token.isNotBlank())
        if (expectedVersion != null && tokenVersion != expectedVersion) return@synchronized
        if (preferences.getString("token", null) == token) return@synchronized
        check(preferences.edit().putString("token", token).putLong("version", tokenVersion + 1).commit())
    }

    suspend fun register(client: Client, userId: String, gateway: String) = registrationLock.withLock {
        val owner = owner(userId)
        while (true) {
            currentCoroutineContext().ensureActive()
            val token = synchronized(tokenLock) { preferences.getString("token", null) } ?: return@withLock
            val previous = preferences.getString("$owner.current", null)
            val stale = preferences.getStringSet("$owner.stale", emptySet())!!.toMutableSet()
            // The server may have dropped the pusher, and setting it again is idempotent.
            client.setPusher(
                PusherIdentifiers(token, appId), PusherKind.Http(HttpPusherData(gateway, PushFormat.EVENT_ID_ONLY, null)),
                appDisplayName = "Slatrix", deviceDisplayName = "Android", profileTag = null,
                lang = Locale.getDefault().toLanguageTag(), append = false,
            )
            if (previous != null && previous != token) stale.add(previous)
            stale.remove(token)
            check(preferences.edit().putString("$owner.current", token).putStringSet("$owner.stale", stale).commit())
            for (old in stale.toList()) {
                client.deletePusher(PusherIdentifiers(old, appId))
                stale.remove(old)
                check(preferences.edit().putStringSet("$owner.stale", stale).commit())
            }
            if (synchronized(tokenLock) { preferences.getString("token", null) } == token) return@withLock
        }
    }

    /** Best effort: a revoked session can't delete its pushers, and the server drops them with the device. */
    suspend fun unregister(client: Client, userId: String) = registrationLock.withLock {
        val owner = owner(userId)
        val tokens = preferences.getStringSet("$owner.stale", emptySet())!! + listOfNotNull(preferences.getString("$owner.current", null))
        for (token in tokens) runCatching { client.deletePusher(PusherIdentifiers(token, appId)) }
        check(preferences.edit().remove("$owner.current").remove("$owner.stale").commit())
    }

    private fun owner(userId: String) = MessageDigest.getInstance("SHA-256").digest(userId.toByteArray()).joinToString("") { "%02x".format(it) }

    companion object {
        private val tokenLock = Any()
        private val registrationLock = Mutex()
    }
}
