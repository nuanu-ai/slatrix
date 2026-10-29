package ai.nuanu.slatrix.core

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import java.io.DataInputStream
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject
import org.matrix.rustcomponents.sdk.Session
import org.matrix.rustcomponents.sdk.SlidingSyncVersion

data class StoredSession(val session: Session, val storeId: String, val storeKey: String) {
    override fun toString(): String = "StoredSession(redacted)"
}

class SessionStore(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "session.enc"))
    private val alias = "${context.packageName}.session.v1"

    fun load(): StoredSession? = synchronized(lock) {
        if (!hasFile()) return@synchronized null
        try {
            val bytes = readFile()
            require(bytes.size >= 30 && bytes[0] == 1.toByte())
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
            cipher.updateAAD(byteArrayOf(1))
            val json = JSONObject(String(cipher.doFinal(bytes, 13, bytes.size - 13), Charsets.UTF_8))
            require(json.getInt("version") == 1)
            val session = json.getJSONObject("session")
            StoredSession(
                Session(
                    accessToken = session.string("accessToken"),
                    refreshToken = session.nullableString("refreshToken"),
                    userId = session.string("userId"),
                    deviceId = session.string("deviceId"),
                    homeserverUrl = session.string("homeserverUrl"),
                    oauthData = session.nullableString("oauthData"),
                    slidingSyncVersion = SlidingSyncVersion.valueOf(session.string("slidingSyncVersion")),
                ),
                storeId = json.string("storeId"),
                storeKey = json.string("storeKey"),
            ).also(::validate)
        } catch (_: Exception) {
            // Parser and crypto exception messages can contain credential material.
            throw IOException("Saved session could not be read")
        }
    }

    fun save(value: StoredSession) = synchronized(lock) {
        try {
            validate(value)
            val session = value.session
            val json = JSONObject()
                .put("version", 1)
                .put("storeId", value.storeId)
                .put("storeKey", value.storeKey)
                .put("session", JSONObject()
                    .put("accessToken", session.accessToken)
                    .put("refreshToken", session.refreshToken ?: JSONObject.NULL)
                    .put("userId", session.userId)
                    .put("deviceId", session.deviceId)
                    .put("homeserverUrl", session.homeserverUrl)
                    .put("oauthData", session.oauthData ?: JSONObject.NULL)
                    .put("slidingSyncVersion", session.slidingSyncVersion.name))
            val plaintext = json.toString().toByteArray(Charsets.UTF_8)
            require(plaintext.size <= MAX_FILE_SIZE - 29)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key(create = !hasFile()))
            cipher.updateAAD(byteArrayOf(1))
            val bytes = byteArrayOf(1) + cipher.iv + cipher.doFinal(plaintext)
            val output = file.startWrite()
            try {
                output.write(bytes)
                output.fd.sync()
                file.finishWrite(output)
            } catch (error: Exception) {
                file.failWrite(output)
                throw error
            }
            // AtomicFile reports a failed rename only in logcat.
            check(readFile().contentEquals(bytes))
        } catch (_: Exception) {
            throw IOException("Session could not be saved")
        }
    }

    fun clear() = synchronized(lock) {
        file.delete()
        if (hasFile()) throw IOException("Saved session could not be removed")
    }

    private fun hasFile(): Boolean = listOf("", ".bak", ".new").any {
        File(file.baseFile.path + it).exists()
    }

    private fun readFile(): ByteArray = file.openRead().use { input ->
        val size = input.channel.size()
        require(size in 1..MAX_FILE_SIZE.toLong())
        ByteArray(size.toInt()).also {
            DataInputStream(input).readFully(it)
            require(input.read() == -1)
        }
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(alias, null)
        if (existing != null) return existing as SecretKey
        check(create)
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build())
        }.generateKey()
    }

    private fun validate(value: StoredSession) {
        require(UUID.fromString(value.storeId).toString() == value.storeId)
        val key = Base64.decode(value.storeKey, Base64.NO_WRAP)
        require(key.size == 32 && Base64.encodeToString(key, Base64.NO_WRAP) == value.storeKey)
        require(value.session.accessToken.isNotBlank())
        require(value.session.userId.isNotBlank())
        require(value.session.deviceId.isNotBlank())
        require(value.session.homeserverUrl.isNotBlank())
    }

    private fun JSONObject.string(name: String): String = get(name) as String
    private fun JSONObject.nullableString(name: String): String? = if (get(name) === JSONObject.NULL) null else string(name)

    private companion object {
        const val MAX_FILE_SIZE = 1024 * 1024
        val lock = Any()
    }
}
