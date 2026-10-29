package ai.nuanu.slatrix.ui.account

import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.PlatformTextInputMethodRequest
import androidx.core.content.FileProvider
import androidx.core.view.inputmethod.EditorInfoCompat
import androidx.core.view.inputmethod.InputConnectionCompat
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Opens the system camera on a file of the app's own and hands the photo over once it is taken. */
@Composable
fun rememberCamera(onPhoto: (Uri) -> Unit): () -> Unit {
    val context = LocalContext.current
    val photo by rememberUpdatedState(onPhoto)
    // Saved, so the photo still arrives when the system recreated the app while the camera was open.
    var pending by rememberSaveable { mutableStateOf<Uri?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { taken ->
        val uri = pending
        pending = null
        if (taken && uri != null) photo(uri)
    }
    return remember(context, camera) {
        {
            val name = "IMG_${SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())}.jpg"
            val file = File(context.cacheDir, "camera").apply { mkdirs() }.resolve(name)
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
            pending = uri
            camera.launch(uri)
        }
    }
}

/**
 * Lets the keyboard insert images and videos, a sticker or a copied screenshot, into [content]'s text field; they come
 * to [onMedia] as attachments. Without [onMedia] the keyboard offers none.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun ReceiveKeyboardMedia(onMedia: ((List<Uri>) -> Unit)?, content: @Composable () -> Unit) {
    val media by rememberUpdatedState(onMedia)
    InterceptPlatformTextInput({ request, next ->
        next.startInputMethod(PlatformTextInputMethodRequest { editor ->
            val connection = request.createInputConnection(editor)
            val receive = media ?: return@PlatformTextInputMethodRequest connection
            EditorInfoCompat.setContentMimeTypes(editor, arrayOf("image/*", "video/*"))
            InputConnectionCompat.createWrapper(connection, editor) { info, flags, _ ->
                // The keyboard's grant lasts until the copy is made; the app keeps it for the rest of its run.
                val granted = Build.VERSION.SDK_INT < 25 || flags and InputConnectionCompat.INPUT_CONTENT_GRANT_READ_URI_PERMISSION == 0 ||
                    runCatching { info.requestPermission() }.isSuccess
                if (granted) receive(listOf(info.contentUri))
                granted
            }
        })
    }, content)
}
