package ai.nuanu.slatrix.ui.account

import android.content.ActivityNotFoundException
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.core.view.inputmethod.InputContentInfoCompat
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Opens the system camera on a file of the app's own and hands the photo over once it is taken; null on a phone
 * without a camera.
 */
@Composable
fun rememberCamera(onPhoto: (Uri) -> Unit): (() -> Unit)? {
    val context = LocalContext.current
    val photo by rememberUpdatedState(onPhoto)
    // Saved, so the photo still arrives when the screen is recreated while the camera is open, as on rotation.
    var pending by rememberSaveable { mutableStateOf<Uri?>(null) }
    val folder = File(context.cacheDir, "camera")
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { taken ->
        val uri = pending
        pending = null
        if (taken && uri != null) photo(uri) else uri?.lastPathSegment?.let { File(folder, it).delete() }
    }
    if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) return null
    return remember(context, camera) {
        {
            // Earlier photos were copied for sending long since; the cache keeps no stale ones.
            folder.listFiles()?.filter { it.lastModified() < System.currentTimeMillis() - DAY_MILLIS }?.forEach { it.delete() }
            val name = "IMG_${SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())}.jpg"
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", folder.apply { mkdirs() }.resolve(name))
            pending = uri
            try { camera.launch(uri) } catch (_: ActivityNotFoundException) { pending = null }
        }
    }
}

private const val DAY_MILLIS = 86_400_000L

/**
 * Lets the keyboard insert images and videos, a sticker or a copied screenshot, into [content]'s text field; they come
 * to [onMedia] as attachments. Without [onMedia] the keyboard offers none.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun ReceiveKeyboardMedia(onMedia: ((List<Uri>) -> Unit)?, content: @Composable () -> Unit) {
    val media by rememberUpdatedState(onMedia)
    // A keyboard's grant lasts while its content info does, so each is kept until the conversation closes.
    val granted = remember { mutableListOf<InputContentInfoCompat>() }
    DisposableEffect(Unit) { onDispose { granted.forEach { it.releasePermission() } } }
    InterceptPlatformTextInput({ request, next ->
        next.startInputMethod(PlatformTextInputMethodRequest { editor ->
            val connection = request.createInputConnection(editor)
            val receive = media ?: return@PlatformTextInputMethodRequest connection
            EditorInfoCompat.setContentMimeTypes(editor, arrayOf("image/*", "video/*"))
            InputConnectionCompat.createWrapper(connection, editor) { info, flags, _ ->
                val readable = Build.VERSION.SDK_INT < 25 || flags and InputConnectionCompat.INPUT_CONTENT_GRANT_READ_URI_PERMISSION == 0 ||
                    runCatching { info.requestPermission() }.isSuccess.also { if (it) granted += info }
                if (readable) receive(listOf(info.contentUri))
                readable
            }
        })
    }, content)
}
