package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.ComposerState
import ai.nuanu.slatrix.core.ConversationState
import ai.nuanu.slatrix.core.RoomSummary
import ai.nuanu.slatrix.core.UnreadBadge
import ai.nuanu.slatrix.ui.account.ComposerActions
import ai.nuanu.slatrix.ui.account.LiveChannelScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Activity
import android.app.Application
import android.content.ClipDescription
import android.content.Intent
import android.net.Uri
import android.view.View
import android.view.inputmethod.EditorInfo
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.core.app.ActivityOptionsCompat
import androidx.core.view.inputmethod.EditorInfoCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import androidx.core.view.inputmethod.InputContentInfoCompat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class ComposerMediaTest {
    @get:Rule val compose = createComposeRule()
    private val room = RoomSummary("!design:example.org", "design", false, "", UnreadBadge.None, "D", 0)
    private val attached = mutableListOf<Uri>()
    private val composer = androidx.compose.runtime.mutableStateOf(ComposerState(loading = false))
    private lateinit var view: View

    private fun show(registry: ActivityResultRegistry? = null) {
        compose.setContent {
            view = LocalView.current
            val owner = registry?.let { object : ActivityResultRegistryOwner { override val activityResultRegistry = it } }
            CompositionLocalProvider(LocalActivityResultRegistryOwner provides (owner ?: LocalActivityResultRegistryOwner.current!!)) {
                SlatrixTheme {
                    LiveChannelScreen(room, ConversationState(emptyList(), loading = false, hasMore = false),
                        composer.value, {}, {}, {}, {}, {}, {}, {}, {},
                        composerActions = ComposerActions(onAttach = { attached += it }))
                }
            }
        }
    }

    // capability: composer.attachments
    @Test fun cameraTakesAPhotoIntoTheAppsOwnFileAndAttachesIt() {
        val context = androidx.test.core.app.ApplicationProvider.getApplicationContext<Application>()
        org.robolectric.Shadows.shadowOf(context.packageManager).setSystemFeature(android.content.pm.PackageManager.FEATURE_CAMERA_ANY, true)
        val asked = mutableListOf<Any?>()
        var result = Activity.RESULT_CANCELED
        show(object : ActivityResultRegistry() {
            override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>, input: I, options: ActivityOptionsCompat?) {
                asked += input
                dispatchResult(requestCode, result, Intent())
            }
        })
        compose.onNodeWithContentDescription("Attachments").performClick()
        compose.onNodeWithText("Camera").performClick()
        compose.runOnIdle { assertTrue("A cancelled photo attaches nothing", attached.isEmpty()) }

        result = Activity.RESULT_OK
        compose.onNodeWithContentDescription("Attachments").performClick()
        compose.onNodeWithText("Camera").performClick()
        compose.runOnIdle {
            val photo = asked.last() as Uri
            // The camera app writes the photo through the URI it was given.
            checkNotNull(context.contentResolver.openOutputStream(photo)).use { it.write(1) }
            assertEquals(listOf(photo), attached)
        }
    }

    // capability: composer.attachments
    @Test fun anImageFromTheKeyboardIsAttached() {
        show()
        compose.onNodeWithContentDescription("Message #design").performClick()
        val image = Uri.parse("content://com.example.keyboard/clip/1")
        compose.runOnIdle {
            val editor = EditorInfo()
            val connection = checkNotNull(view.onCreateInputConnection(editor))
            assertTrue(EditorInfoCompat.getContentMimeTypes(editor).any { it.startsWith("image/") })
            assertTrue(InputConnectionCompat.commitContent(connection, editor,
                InputContentInfoCompat(image, ClipDescription("sticker", arrayOf("image/png")), null), 0, null))
            assertEquals(listOf(image), attached)
        }

        composer.value = ComposerState(loading = false, target = ai.nuanu.slatrix.core.ComposerTarget.Edit("\$one", "Typo"))
        compose.runOnIdle {
            val editor = EditorInfo()
            view.onCreateInputConnection(editor)
            assertTrue("An edit takes no attachments", EditorInfoCompat.getContentMimeTypes(editor).isEmpty())
        }
    }

    @Test fun withoutACameraPlusOffersNone() {
        show()
        compose.onNodeWithContentDescription("Attachments").performClick()
        compose.onNodeWithText("Files").assertExists()
        compose.onNodeWithText("Camera").assertDoesNotExist()
    }
}
