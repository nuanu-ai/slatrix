package ai.nuanu.slatrix

import android.content.ContextWrapper
import ai.nuanu.slatrix.core.AccountState
import ai.nuanu.slatrix.core.MatrixAccount
import ai.nuanu.slatrix.core.SessionStore
import ai.nuanu.slatrix.core.StoredSession
import ai.nuanu.slatrix.ui.account.SlatrixApp
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.matrix.rustcomponents.sdk.OAuthConfiguration
import org.matrix.rustcomponents.sdk.Session
import org.matrix.rustcomponents.sdk.SlidingSyncVersion

@RunWith(AndroidJUnit4::class)
class LaunchTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val target = InstrumentationRegistry.getInstrumentation().targetContext
    private val directory = File(target.cacheDir, "launch-test-${UUID.randomUUID()}")
    private val context = object : ContextWrapper(target) {
        override fun getNoBackupFilesDir(): File = directory
        override fun getPackageName(): String = "${target.packageName}.${directory.name}"
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val store = SessionStore(context)

    @Before fun setUp() { check(directory.mkdirs()) }
    @After fun tearDown() {
        scope.cancel()
        store.clear()
        directory.deleteRecursively()
    }

    @Test fun restoringShowsOnlyTheBackgroundAndARetryKeepsTheRestoreScreen() {
        store.save(StoredSession(
            Session("test-access-token", "test-refresh-token", "@alice:example.org", "ANDROID", "https://matrix.example.org",
                null, SlidingSyncVersion.NATIVE),
            "9de7b914-3890-4354-b3bb-8f4f53f0ee63", "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
        ))
        val restores = ArrayDeque(listOf(CompletableDeferred<Unit>(), CompletableDeferred()))
        val firstRestore = restores.first()
        val account = MatrixAccount(scope, store, File(directory, "matrix"), OAuthConfiguration(
            "Slatrix", "com.github.nuanu-ai.slatrix.dev:/oauth/callback", "https://github.com/nuanu-ai/slatrix",
            null, null, null, emptyMap(),
        )) { _, _, _, _, _ ->
            restores.removeFirst().await()
            error("fictional unreachable homeserver")
        }
        compose.setContent { SlatrixApp(account, null, null, null) }
        account.restore()

        compose.onNodeWithText("Restore your session").assertDoesNotExist()
        compose.runOnIdle {
            assertFalse("Back during launch leaves the app and keeps the session",
                compose.activity.onBackPressedDispatcher.hasEnabledCallbacks())
        }

        firstRestore.complete(Unit)
        compose.waitUntil(5_000) { compose.onAllNodesWithText("Sign in again").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Try again").performClick()
        compose.waitUntil(5_000) { (account.state.value as? AccountState.Connecting)?.restoring == true }
        compose.onNodeWithText("Restore your session").assertExists()
        compose.onNodeWithText("Cancel").assertDoesNotExist()
    }
}
