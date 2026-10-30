package ai.nuanu.slatrix

import ai.nuanu.slatrix.core.CropSquare
import ai.nuanu.slatrix.core.Person
import ai.nuanu.slatrix.ui.account.LiveYouScreen
import ai.nuanu.slatrix.ui.account.PersonProfileScreen
import ai.nuanu.slatrix.ui.account.EditProfileScreen
import ai.nuanu.slatrix.ui.account.PhotoCropScreen
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import android.app.Application
import android.graphics.Bitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Editing your profile: the name, the photo and its crop. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(application = Application::class, sdk = [35], qualifiers = "w411dp-h914dp-420dpi")
class EditProfileScreenTest {
    @get:Rule val compose = createComposeRule()

    // capability: profile.edit-name
    @Test fun saveSendsTheNewNameOnlyOnceItChanged() {
        val saved = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                EditProfileScreen("@alex:example.org", "Alex", photo = null, hasPhoto = false, saving = false, error = null,
                    onPickPhoto = {}, onRemovePhoto = {}, onSave = { saved += it }, onBack = {})
            }
        }
        compose.onNodeWithText("Save").assertIsNotEnabled()
        compose.onNode(hasSetTextAction()).performTextClearance()
        compose.onNodeWithText("Save").assertIsNotEnabled()
        compose.onNode(hasSetTextAction()).performTextInput("  Alex Doe ")
        compose.onNodeWithText("Save").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(listOf("Alex Doe"), saved) }
    }

    // capability: profile.edit-name
    @Test fun youLeadsToYourProfile() {
        val asked = mutableListOf<String>()
        compose.setContent { SlatrixTheme { LiveYouScreen("@alex:example.org", { "Alex Doe" }, {}, {}, onViewProfile = { asked += "view" }, onBack = {}) } }
        compose.onNodeWithText("View profile").performClick()
        compose.runOnIdle { assertEquals(listOf("view"), asked) }
    }

    // capability: profile.edit-name
    @Test fun yourProfileLeadsToEditProfile() {
        val asked = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                PersonProfileScreen(Person("@alex:example.org", "Alex Doe"), own = true, opening = false, error = null, onMessage = {},
                    onEdit = { asked += "edit" }, onBack = {})
            }
        }
        compose.onNodeWithText("Edit profile").performClick()
        compose.runOnIdle { assertEquals(listOf("edit"), asked) }
    }

    // capability: profile.edit-photo
    @Test fun aPhotoCanBeUploadedOrRemoved() {
        val asked = mutableListOf<String>()
        compose.setContent {
            SlatrixTheme {
                EditProfileScreen("@alex:example.org", "Alex", photo = null, hasPhoto = true, saving = false, error = null,
                    onPickPhoto = { asked += "upload" }, onRemovePhoto = { asked += "remove" }, onSave = {}, onBack = {})
            }
        }
        compose.onNodeWithText("Upload photo").performClick()
        compose.onNodeWithText("Remove photo").performClick()
        compose.runOnIdle { assertEquals(listOf("upload", "remove"), asked) }
    }

    @Test fun withoutAPhotoThereIsNothingToRemove() {
        compose.setContent {
            SlatrixTheme {
                EditProfileScreen("@alex:example.org", "Alex", photo = null, hasPhoto = false, saving = false, error = null,
                    onPickPhoto = {}, onRemovePhoto = {}, onSave = {}, onBack = {})
            }
        }
        compose.onNodeWithText("Remove photo").assertDoesNotExist()
    }

    // capability: profile.edit-photo
    @Test fun aNewPhotoCropsToTheLargestSquareInTheMiddleUnlessMoved() {
        val cropped = mutableListOf<CropSquare>()
        val photo = Bitmap.createBitmap(300, 200, Bitmap.Config.ARGB_8888).asImageBitmap()
        compose.setContent { SlatrixTheme { PhotoCropScreen(photo, onCancel = {}, onSave = { cropped += it }) } }
        compose.onNodeWithText("Save").performClick()
        compose.runOnIdle { assertEquals(listOf(CropSquare(50f, 0f, 200f)), cropped) }
    }

    // capability: profile.edit-photo
    @Test fun draggingTheFrameMovesItAndItStopsAtThePhotosEdge() {
        val cropped = mutableListOf<CropSquare>()
        val photo = Bitmap.createBitmap(300, 200, Bitmap.Config.ARGB_8888).asImageBitmap()
        compose.setContent { SlatrixTheme { PhotoCropScreen(photo, onCancel = {}, onSave = { cropped += it }) } }
        compose.onRoot().performTouchInput { swipe(center, center + Offset(2_000f, 0f), 300) }
        compose.onNodeWithText("Save").performClick()
        compose.runOnIdle { assertEquals(listOf(CropSquare(100f, 0f, 200f)), cropped) }
    }
}
