package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.AvatarPlaceholder
import ai.nuanu.slatrix.core.CropSquare
import ai.nuanu.slatrix.core.MatrixProfile
import ai.nuanu.slatrix.core.PhotoChange
import ai.nuanu.slatrix.core.PhotoCrop
import ai.nuanu.slatrix.core.ProfilePhoto
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.DpSize
import kotlin.math.abs
import kotlin.math.min
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.matrix.rustcomponents.sdk.Client

/**
 * Slack's Edit profile, as the Mac's editor does it: your photo, to upload or remove, and your display name, all saved
 * by Save. Save waits for a change and a name.
 */
@Composable
fun EditProfileScreen(userId: String, name: String, photo: ImageBitmap?, hasPhoto: Boolean, saving: Boolean, error: String?,
    onPickPhoto: () -> Unit, onRemovePhoto: () -> Unit, onSave: (String) -> Unit, onBack: () -> Unit, photoChanged: Boolean = false) {
    val colors = SlatrixTheme.colors
    var text by rememberSaveable(name) { mutableStateOf(name) }
    val trimmed = text.trim()
    val canSave = !saving && trimmed.isNotEmpty() && (trimmed != name || photoChanged)
    Box(Modifier.fillMaxSize()) {
        PushedPage("Edit profile", onBack, action = {
            Box(Modifier.padding(end = UiMetrics.GapSmall), contentAlignment = Alignment.Center) {
                TextButton({ onSave(trimmed) }, enabled = canSave) { Text("Save", fontWeight = FontWeight.Bold) }
                if (saving) DelayedSpinner()
            }
        }) {
            item {
                Column(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                    val shown = text.ifBlank { name }.ifBlank { userId }
                    // The new photo shows as it will look; until then, the photo you have, or your initials.
                    if (photo != null) Image(photo, null, Modifier.size(UiMetrics.ProfilePhoto).clip(MaterialTheme.shapes.large))
                    else LiveAvatar(AvatarPlaceholder.initials(shown), AvatarPlaceholder.colorIndex(userId), UiMetrics.ProfilePhoto)
                    OutlinedButton(onPickPhoto, Modifier.heightIn(min = UiMetrics.Touch), enabled = !saving, shape = MaterialTheme.shapes.small) {
                        Text("Upload photo", color = colors.textPrimary)
                    }
                    if (hasPhoto) TextButton(onRemovePhoto, Modifier.heightIn(min = UiMetrics.Touch), enabled = !saving) {
                        Text("Remove photo", color = colors.destructive)
                    }
                    OutlinedTextField(text, { text = it }, Modifier.fillMaxWidth(), enabled = !saving, singleLine = true,
                        label = { Text("Display name") }, shape = MaterialTheme.shapes.small)
                }
            }
        }
        error?.let {
            Snackbar(Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(UiMetrics.GapLarge)
                .semantics { liveRegion = LiveRegionMode.Polite }) { Text(it) }
        }
    }
}

/**
 * Slack's crop: the photo, and a square over it to drag by its middle or resize by a corner, inside the photo. It opens
 * on the largest square in the middle, and Save gives the square in the photo's pixels.
 */
@Composable
fun PhotoCropScreen(photo: ImageBitmap, onCancel: () -> Unit, onSave: (CropSquare) -> Unit) {
    val colors = SlatrixTheme.colors
    val width = photo.width.toFloat()
    val height = photo.height.toFloat()
    var square by remember(photo) { mutableStateOf(PhotoCrop.centered(width, height)) }
    BackHandler(onBack = onCancel)
    Column(Modifier.fillMaxSize().background(colors.mediaBackdrop).navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.ComposerMinHeight).padding(horizontal = UiMetrics.GapSmall),
            verticalAlignment = Alignment.CenterVertically) {
            TextButton(onCancel) { Text("Cancel", color = colors.onMedia) }
            Text("Crop photo", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold,
                color = colors.onMedia, textAlign = TextAlign.Center)
            TextButton({ onSave(square) }) { Text("Save", color = colors.onMedia, fontWeight = FontWeight.Bold) }
        }
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().padding(UiMetrics.GapLarge), contentAlignment = Alignment.Center) {
            val density = LocalDensity.current
            // The photo fits the space; a pixel of it is this many pixels on screen.
            val scale = min(constraints.maxWidth / width, constraints.maxHeight / height)
            val shown = with(density) { DpSize((width * scale).toDp(), (height * scale).toDp()) }
            val handle = with(density) { UiMetrics.Touch.toPx() }
            Box(Modifier.size(shown)) {
                Image(photo, null, Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
                Canvas(Modifier.fillMaxSize().pointerInput(photo, scale) {
                    var corner: PhotoCrop.Corner? = null
                    detectDragGestures(onDragStart = { at ->
                        val s = square
                        // A touch near a corner resizes from it; anywhere else moves the frame.
                        corner = PhotoCrop.Corner.entries.firstOrNull { c ->
                            val x = (s.x + if (c.right) s.side else 0f) * scale
                            val y = (s.y + if (c.bottom) s.side else 0f) * scale
                            abs(at.x - x) < handle && abs(at.y - y) < handle
                        }
                    }) { change, drag ->
                        change.consume()
                        val dx = drag.x / scale
                        val dy = drag.y / scale
                        square = corner?.let { PhotoCrop.resized(square, it, dx, dy, width, height) }
                            ?: PhotoCrop.moved(square, dx, dy, width, height)
                    }
                }) {
                    val left = square.x * scale
                    val top = square.y * scale
                    val side = square.side * scale
                    // Shades what the crop leaves out.
                    drawRect(colors.mediaShade, Offset.Zero, Size(size.width, top))
                    drawRect(colors.mediaShade, Offset(0f, top + side), Size(size.width, size.height - top - side))
                    drawRect(colors.mediaShade, Offset(0f, top), Size(left, side))
                    drawRect(colors.mediaShade, Offset(left + side, top), Size(size.width - left - side, side))
                    drawRect(colors.onMedia, Offset(left, top), Size(side, side), style = Stroke(with(density) { UiMetrics.Divider.toPx() } * 2))
                    // A knob at each corner, where a drag resizes.
                    val knob = with(density) { UiMetrics.GapMedium.toPx() }
                    for (corner in PhotoCrop.Corner.entries) {
                        val x = left + if (corner.right) side else 0f
                        val y = top + if (corner.bottom) side else 0f
                        drawRect(colors.onMedia, Offset(x - knob / 2, y - knob / 2), Size(knob, knob))
                    }
                }
            }
        }
    }
}

/**
 * Edit profile, live: your name and photo as the account has them; a picked photo goes through the crop first, and Save
 * sends what changed, then goes back.
 */
@Composable
fun LiveEditProfile(client: Client?, userId: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val current by produceState<Pair<String, Boolean>?>(null, client) {
        value = client?.let { runCatching { it.displayName() to (it.avatarUrl() != null) }.getOrNull() } ?: ("" to false)
    }
    var picked by remember { mutableStateOf<Bitmap?>(null) }
    var change by remember { mutableStateOf<PhotoChange?>(null) }
    var preview by remember { mutableStateOf<ImageBitmap?>(null) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch {
            picked = ProfilePhoto.load(context, uri)
            if (picked == null) error = "Choose an image file."
        }
    }
    val photo = picked
    if (photo != null) {
        PhotoCropScreen(remember(photo) { photo.asImageBitmap() }, { picked = null }) { crop ->
            picked = null
            scope.launch {
                val upload = withContext(Dispatchers.Default) { ProfilePhoto.encode(photo, crop) }
                if (upload == null) error = "Choose an image file."
                else {
                    change = PhotoChange.Upload(upload.data, upload.mimeType)
                    preview = withContext(Dispatchers.Default) {
                        android.graphics.BitmapFactory.decodeByteArray(upload.data, 0, upload.data.size)?.asImageBitmap()
                    }
                }
            }
        }
        return
    }
    // Waits for your name, so the field never starts empty and fills in.
    val (name, hadPhoto) = current ?: return
    EditProfileScreen(userId, name, preview, hasPhoto = if (change == null) hadPhoto else change is PhotoChange.Upload, saving, error,
        onPickPhoto = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
        onRemovePhoto = { change = PhotoChange.Remove; preview = null },
        onSave = { newName ->
            val account = client ?: return@EditProfileScreen
            saving = true
            error = null
            scope.launch {
                error = MatrixProfile(account).save(newName.takeIf { it != name }, change)
                saving = false
                if (error == null) onBack()
            }
        }, onBack = onBack, photoChanged = change != null)
    error?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); error = null } }
}
