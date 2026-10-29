package ai.nuanu.slatrix.core

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.Session
import org.matrix.rustcomponents.sdk.SlidingSyncVersion

@RunWith(AndroidJUnit4::class)
class SessionStoreTest {
    private val target = InstrumentationRegistry.getInstrumentation().targetContext
    private val directory = File(target.cacheDir, "session-test-${UUID.randomUUID()}")
    private val context = object : ContextWrapper(target) {
        override fun getNoBackupFilesDir(): File = directory
        override fun getPackageName(): String = "${target.packageName}.${directory.name}"
    }
    private val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    @Before fun setUp() {
        check(directory.mkdirs())
    }

    @After fun tearDown() {
        removeTestKeys()
        directory.deleteRecursively()
    }

    @Test fun unavailableStorageIsNotAnEmptySession() {
        check(directory.delete())
        directory.writeText("unavailable storage")

        assertThrows(IOException::class.java) { SessionStore(context).load() }
    }

    @Test fun encryptedSessionSurvivesReopening() {
        val session = storedSession()
        SessionStore(context).save(session)

        assertEquals(session, SessionStore(context).load())
        val diskContents = directory.walkTopDown().filter { it.isFile }
            .joinToString { it.readBytes().toString(Charsets.ISO_8859_1) }
        assertFalse(diskContents.contains(session.session.accessToken))
        assertFalse(diskContents.contains(session.session.refreshToken!!))
        assertFalse(diskContents.contains(session.storeKey))
    }

    @Test fun corruptSessionIsRejectedWithoutRemovingItsBytes() {
        SessionStore(context).save(storedSession())
        val file = directory.listFiles()!!.single()
        val encrypted = file.readBytes()
        val tampered = encrypted.copyOf().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }

        for (corrupt in listOf(encrypted.copyOf(10), tampered)) {
            file.writeBytes(corrupt)
            assertThrows(IOException::class.java) { SessionStore(context).load() }
            assertArrayEquals(corrupt, file.readBytes())
        }
    }

    @Test fun missingKeystoreKeyDoesNotReplaceTheSavedSession() {
        val session = storedSession()
        SessionStore(context).save(session)
        val file = directory.listFiles()!!.single()
        val encrypted = file.readBytes()
        removeTestKeys()

        assertThrows(IOException::class.java) { SessionStore(context).load() }
        assertThrows(IOException::class.java) { SessionStore(context).save(session) }
        assertArrayEquals(encrypted, file.readBytes())
    }

    @Test fun invalidReplacementKeepsTheSavedSession() {
        val session = storedSession()
        SessionStore(context).save(session)

        assertThrows(IOException::class.java) {
            SessionStore(context).save(session.copy(storeKey = "AAECAwQFBgcICQoLDA0ODw=="))
        }
        assertEquals(session, SessionStore(context).load())
    }

    @Test fun refreshedSessionReplacesTokensAndKeepsDatabaseIdentity() {
        val session = storedSession()
        SessionStore(context).save(session)
        val refreshed = session.copy(session = session.session.copy(
            accessToken = "fictional-new-access-secret",
            refreshToken = null,
            oauthData = null,
            slidingSyncVersion = SlidingSyncVersion.NONE,
        ))
        SessionStore(context).save(refreshed)

        assertEquals(refreshed, SessionStore(context).load())
    }

    @Test fun clearedSessionIsAbsent() {
        SessionStore(context).save(storedSession())
        SessionStore(context).clear()
        assertNull(SessionStore(context).load())
    }

    private fun removeTestKeys() {
        keys.aliases().toList().filter { it.startsWith("${context.packageName}.") }.forEach(keys::deleteEntry)
    }

    private fun storedSession() = StoredSession(
        Session(
            accessToken = "fictional-access-secret",
            refreshToken = "fictional-refresh-secret",
            userId = "@alice:example.org",
            deviceId = "FICTIONAL_DEVICE",
            homeserverUrl = "https://matrix.example.org/",
            oauthData = "{\"fictional\":\"oauth-secret\"}",
            slidingSyncVersion = SlidingSyncVersion.NATIVE,
        ),
        storeId = "9de7b914-3890-4354-b3bb-8f4f53f0ee63",
        storeKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
    )
}
