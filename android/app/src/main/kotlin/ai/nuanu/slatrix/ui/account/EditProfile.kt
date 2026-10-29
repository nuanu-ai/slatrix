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
import androidx.core.net.toUri
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
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
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
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.DpSize
import kotlin.math.min
import kotlinx.coroutines.CancellationException
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
    onPickPhoto: () -> Unit, onRemovePhoto: () -> Unit, onSave: (String) -> Unit, onBack: () -> Unit, photoChanged: Boolean = false,
    photoUrl: String? = null) {
    val colors = SlatrixTheme.colors
    var text by rememberSaveable(name) { mutableStateOf(name) }
    val trimmed = text.trim()
    val canSave = !saving && trimmed.isNotEmpty() && (trimmed != name || photoChanged)
    Box(Modifier.fillMaxSize()) {
        PushedPage("Edit profile", onBack, action = {
            Box(Modifier.padding(end = UiMetrics.GapSmall), contentAlignment = Alignment.Center) {
                TextButton({ onSave(trimmed) }, enabled = canSave) { Text("Save", fontWeight = FontWeight.Bold) }
                if (saving) WaitingSpinner()
            }
        }) {
            item {
                Column(Modifier.fillMaxWidth().padding(UiMetrics.GapLarge), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium)) {
                    val shown = text.ifBlank { name }.ifBlank { userId }
                    // The new photo shows as it will look; until then, the photo you have, or your initials.
                    if (photo != null) Image(photo, null, Modifier.size(UiMetrics.ProfilePhoto).clip(MaterialTheme.shapes.large))
                    else LiveAvatar(AvatarPlaceholder.initials(shown), AvatarPlaceholder.colorIndex(userId), UiMetrics.ProfilePhoto, photoUrl)
                    OutlinedButton(onPickPhoto, Modifier.heightIn(min = UiMetrics.Touch), enabled = !saving, shape = MaterialTheme.shapes.small) {
                        Text("Upload photo", color = colors.textPrimary)
                    }
                    // Hidden, not removed, so the field below never moves, as on the Mac.
                    TextButton(onRemovePhoto, Modifier.heightIn(min = UiMetrics.Touch).alpha(if (hasPhoto) 1f else 0f)
                        .then(if (hasPhoto) Modifier else Modifier.clearAndSetSemantics {}), enabled = hasPhoto && !saving) {
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
    var square by rememberSaveable(photo, saver = cropSaver) { mutableStateOf<CropSquare?>(PhotoCrop.centered(width, height)) }
    val shownSquare = square ?: PhotoCrop.centered(width, height)
    BackHandler(onBack = onCancel)
    Column(Modifier.fillMaxSize().background(colors.mediaBackdrop).navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().heightIn(min = UiMetrics.ComposerMinHeight).padding(horizontal = UiMetrics.GapSmall),
            verticalAlignment = Alignment.CenterVertically) {
            TextButton(onCancel) { Text("Cancel", color = colors.onMedia) }
            Text("Crop photo", Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold,
                color = colors.onMedia, textAlign = TextAlign.Center)
            TextButton({ onSave(shownSquare) }) { Text("Save", color = colors.onMedia, fontWeight = FontWeight.Bold) }
        }
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().padding(UiMetrics.GapLarge), contentAlignment = Alignment.Center) {
            val density = LocalDensity.current
            // The photo fits the space; a pixel of it is this many pixels on screen.
            val scale = min(constraints.maxWidth / width, constraints.maxHeight / height)
            val shown = with(density) { DpSize((width * scale).toDp(), (height * scale).toDp()) }
            val handle = with(density) { UiMetrics.Touch.toPx() } / 2
            Box(Modifier.size(shown)) {
                Image(photo, null, Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
                Canvas(Modifier.fillMaxSize().pointerInput(photo, scale) {
                    var corner: PhotoCrop.Corner? = null
                    var start = shownSquare
                    var total = Offset.Zero
                    detectDragGestures(onDragStart = { at ->
                        start = square ?: PhotoCrop.centered(width, height)
                        total = Offset.Zero
                        // A touch on a corner resizes from the nearest one; anywhere else moves the frame.
                        fun distance(c: PhotoCrop.Corner) = (Offset((start.x + if (c.right) start.side else 0f) * scale,
                            (start.y + if (c.bottom) start.side else 0f) * scale) - at).getDistance()
                        corner = PhotoCrop.Corner.entries.minBy(::distance).takeIf { distance(it) < handle }
                    }) { change, drag ->
                        change.consume()
                        // From where the drag began, as on the Mac, so the frame stays under the finger after an edge.
                        total += drag
                        val dx = total.x / scale
                        val dy = total.y / scale
                        square = corner?.let { PhotoCrop.resized(start, it, dx, dy, width, height) } ?: PhotoCrop.moved(start, dx, dy, width, height)
                    }
                }) {
                    val left = shownSquare.x * scale
                    val top = shownSquare.y * scale
                    val side = shownSquare.side * scale
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
                        // Inside the frame, so a knob never hangs off the photo.
                        drawRect(colors.onMedia, Offset(if (corner.right) x - knob else x, if (corner.bottom) y - knob else y), Size(knob, knob))
                    }
                }
            }
        }
    }
}

/**
 * Edit profile, live: your name and photo as the account has them. A picked photo goes through the crop first; what you
 * picked and how you cropped it outlive a rotation, and the photo is encoded only at Save, as on the Mac. Save sends what
 * changed, then goes back, and can't be left halfway.
 */
@Composable
fun LiveEditProfile(client: Client?, userId: String, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    val current by produceState<Pair<String, String?>?>(null, client) {
        value = try {
            client?.let { it.displayName() to it.avatarUrl() } ?: ("" to null)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            error = "Couldn’t load your profile."
            "" to null
        }
    }
    var picked by rememberSaveable { mutableStateOf<String?>(null) }
    var cropping by rememberSaveable { mutableStateOf(false) }
    var crop by rememberSaveable(saver = cropSaver) { mutableStateOf<CropSquare?>(null) }
    var removed by rememberSaveable { mutableStateOf(false) }
    // A name saved before the photo failed, so trying again sends only the photo.
    var savedName by rememberSaveable { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    var preparing by remember { mutableStateOf(false) }
    val photo by produceState<Bitmap?>(null, picked) {
        value = picked?.let { uri ->
            preparing = true
            ProfilePhoto.load(context, uri.toUri()).also {
                preparing = false
                if (it == null) {
                    error = "Choose an image file."
                    picked = null
                    cropping = false
                }
            }
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) {
            picked = uri.toString()
            crop = null
            cropping = true
            removed = false
        }
    }
    val bitmap = photo
    if (cropping && bitmap != null) {
        PhotoCropScreen(remember(bitmap) { bitmap.asImageBitmap() }, { cropping = false; if (crop == null) picked = null }) {
            crop = it
            cropping = false
        }
        return
    }
    BackHandler(enabled = saving) {}
    val loaded = current
    // Waits for your name, so the field never starts empty and fills in.
    if (loaded == null) return PushedPage("Edit profile", onBack) {}
    val name = savedName ?: loaded.first
    val square = crop
    val preview = remember(bitmap, square) {
        if (bitmap == null || square == null) null
        else Bitmap.createBitmap(bitmap, square.x.toInt(), square.y.toInt(), min(square.side.toInt(), bitmap.width - square.x.toInt()),
            min(square.side.toInt(), bitmap.height - square.y.toInt())).asImageBitmap()
    }
    EditProfileScreen(userId, name, preview, hasPhoto = preview != null || (!removed && loaded.second != null), saving || preparing, error,
        onPickPhoto = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
        onRemovePhoto = { removed = true; picked = null; crop = null },
        onSave = { newName ->
            if (client == null || saving) return@EditProfileScreen
            saving = true
            error = null
            scope.launch {
                val upload = if (bitmap != null && square != null) withContext(Dispatchers.Default) { ProfilePhoto.encode(bitmap, square) } else null
                val change = upload?.let { PhotoChange.Upload(it.data, it.mimeType) } ?: PhotoChange.Remove.takeIf { removed }
                val sentName = newName.takeIf { it != name }
                error = if (square != null && upload == null) "Choose an image file." else MatrixProfile(client).save(sentName, change)
                if (sentName != null && error != "Couldn’t save your name.") savedName = sentName
                saving = false
                if (error == null) onBack()
            }
        }, onBack = onBack, photoChanged = removed || preview != null, photoUrl = loaded.second.takeUnless { removed })
    error?.let { LaunchedEffect(it) { delay(UiMetrics.NoticeMillis); error = null } }
}

/** Keeps a crop through a rotation. */
private val cropSaver = listSaver<MutableState<CropSquare?>, Float>(
    save = { state -> state.value?.let { listOf(it.x, it.y, it.side) }.orEmpty() },
    restore = { values -> mutableStateOf(values.takeIf { it.size == 3 }?.let { CropSquare(it[0], it[1], it[2]) }) },
)
