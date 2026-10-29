package ai.nuanu.slatrix.core

import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    @Before fun setUp() { check(directory.mkdirs()) }
    @After fun tearDown() { directory.deleteRecursively() }

    @Test fun encryptedSessionSurvivesReopening() {
        val session = StoredSession(
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
        SessionStore(context).save(session)

        assertEquals(session, SessionStore(context).load())
        val diskContents = directory.walkTopDown().filter { it.isFile }
            .joinToString { it.readBytes().toString(Charsets.ISO_8859_1) }
        assertFalse(diskContents.contains(session.session.accessToken))
        assertFalse(diskContents.contains(session.session.refreshToken!!))
        assertFalse(diskContents.contains(session.storeKey))
    }
}
