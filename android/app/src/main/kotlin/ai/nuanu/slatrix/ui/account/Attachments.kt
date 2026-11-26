package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.FileKind
import ai.nuanu.slatrix.core.MatrixMedia
import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.core.SvgDecoder
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.Motion
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import ai.nuanu.slatrix.ui.designsystem.isMotionReduced
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.text.format.Formatter
import android.util.LruCache
import android.webkit.MimeTypeMap
import android.widget.ImageView
import androidx.core.graphics.scale
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.input.pointer.util.VelocityTracker
import kotlin.math.abs
import kotlin.math.sign
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.key
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToUp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Share
import androidx.compose.ui.viewinterop.AndroidView
import java.io.File
import java.nio.ByteBuffer
import kotlinx.coroutines.launch
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.min
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.FileProvider
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

internal fun resolveAttachmentMimeType(context: Context, uri: Uri, name: String, rawMime: String?): String {
    val clean = rawMime?.substringBefore(';')?.trim()?.lowercase()
    val ext = FileKind.extension(name).lowercase()
    if (ext == "svg" && (clean.isNullOrBlank() || clean == "application/octet-stream" || clean == "*/*" ||
        clean == "application/xml" || clean == "text/xml")) {
        return "image/svg+xml"
    }
    if (!clean.isNullOrBlank() && clean != "application/octet-stream" && clean != "*/*") return clean
    val fromExt = ext.takeIf { it.isNotEmpty() }?.let { MimeTypeMap.getSingleton().getMimeTypeFromExtension(it) }
    if (!fromExt.isNullOrBlank()) return fromExt
    return context.contentResolver.getType(uri)?.substringBefore(';')?.trim()?.takeIf { it.isNotBlank() } ?: "*/*"
}

/**
 * Downloads the file and hands it to the app the phone opens its kind with, as Slack does. Says why when it can't, for
 * the conversation to show.
 */
internal suspend fun openAttachment(context: Context, media: MatrixMedia, attachment: MessageAttachment): String? {
    val file = try {
        media.file(attachment)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        return "Couldn’t download ${attachment.name}."
    }
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    val type = resolveAttachmentMimeType(context, uri, attachment.name, attachment.mimeType)
    return try {
        context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
        null
    } catch (_: ActivityNotFoundException) {
        "No app on this phone opens ${attachment.name}."
    }
}

/** Hands the downloaded file to an app the reader picks from the phone's share sheet. */
internal fun shareFile(context: Context, file: File, attachment: MessageAttachment) {
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    val type = resolveAttachmentMimeType(context, uri, attachment.name, attachment.mimeType)
    val send = Intent(Intent.ACTION_SEND).setType(type)
        .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

/** Copies the downloaded file into Pictures, Movies, or Downloads (for SVGs and documents). */
internal suspend fun saveFile(context: Context, file: File, attachment: MessageAttachment): String = withContext(Dispatchers.IO) {
    val safeName = attachment.name.substringAfterLast('/').substringAfterLast('\\').trim()
        .takeUnless { it.isEmpty() || it == "." || it == ".." } ?: "file"
    val rawClean = attachment.mimeType?.substringBefore(';')?.trim()?.lowercase()
    val isSvgName = safeName.endsWith(".svg", ignoreCase = true)
    val cleanMime = when {
        isSvgName && (rawClean.isNullOrBlank() || rawClean == "application/octet-stream" || rawClean == "*/*" ||
            rawClean == "application/xml" || rawClean == "text/xml") -> "image/svg+xml"
        !rawClean.isNullOrBlank() && rawClean != "application/octet-stream" && rawClean != "*/*" -> rawClean
        else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(FileKind.extension(safeName).lowercase())
    }
    val video = attachment.kind == MessageAttachment.Kind.Video
    val rasterImage = attachment.kind == MessageAttachment.Kind.Image && cleanMime != "image/svg+xml" &&
        !safeName.endsWith(".svg", ignoreCase = true)
    val (folder, collection, destinationLabel) = when {
        video -> Triple(Environment.DIRECTORY_MOVIES,
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), "Movies")
        rasterImage -> Triple(Environment.DIRECTORY_PICTURES,
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), "Pictures")
        else -> Triple(Environment.DIRECTORY_DOWNLOADS,
            MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), "Downloads")
    }
    val resolver = context.contentResolver
    val values = ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
        cleanMime?.let { put(MediaStore.MediaColumns.MIME_TYPE, it) }
        put(MediaStore.MediaColumns.RELATIVE_PATH, "$folder/Slatrix")
        put(MediaStore.MediaColumns.IS_PENDING, 1)
    }
    var uri: Uri? = null
    try {
        uri = resolver.insert(collection, values) ?: return@withContext "Couldn’t save ${attachment.name}."
        resolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
        resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        "Saved to $destinationLabel"
    } catch (_: Exception) {
        // A half-written copy would show in the gallery broken.
        uri?.let { runCatching { resolver.delete(it, null, null) } }
        "Couldn’t save ${attachment.name}."
    }
}

/** Fetches a picture of an attachment no bigger than the pixels asked for; [full] asks for the original, for the viewer. */
typealias PictureLoader = suspend (MessageAttachment, width: Int, height: Int, full: Boolean) -> ByteArray?

/** Shared across conversations only within the connected client. */
internal class SessionPictures : LruCache<PictureKey, ImageBitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
    override fun sizeOf(key: PictureKey, value: ImageBitmap) = value.width * value.height * 4
}
internal data class PictureKey(val source: Pair<String, String?>, val width: Int, val height: Int, val full: Boolean)
internal val LocalPictures = staticCompositionLocalOf<SessionPictures?> { null }

internal data class PictureLoadState(
    val bitmap: ImageBitmap? = null,
    val animated: AnimatedImageDrawable? = null,
    val settled: Boolean = false,
)

/** Decodes off the main thread; resizing keeps the current source visible while the new size loads. */
@Composable
internal fun picture(attachment: MessageAttachment, width: Int, height: Int, full: Boolean, load: PictureLoader): ImageBitmap? =
    pictureState(attachment, width, height, full, allowAnimation = false, load).bitmap

/**
 * Loads and decodes an attachment ONCE: returns an `AnimatedImageDrawable` for animated GIF/WebP when [allowAnimation]
 * is true, otherwise caches and returns a static `ImageBitmap` (preventing concurrent double-fetches).
 */
@Composable
private fun pictureState(
    attachment: MessageAttachment,
    width: Int,
    height: Int,
    full: Boolean,
    allowAnimation: Boolean,
    load: PictureLoader,
): PictureLoadState {
    val pictures = LocalPictures.current ?: remember { SessionPictures() }
    val source = attachment.source.toJson() to attachment.thumbnail?.toJson()
    val maybeAnimated = allowAnimation && (attachment.animated ||
        attachment.mimeType?.equals("image/gif", ignoreCase = true) == true ||
        attachment.mimeType?.equals("image/webp", ignoreCase = true) == true)
    val cacheKey = PictureKey(source, width, height, full)
    return key(pictures) {
        val state by produceState(
            if (!maybeAnimated) pictures[cacheKey]?.let { source to PictureLoadState(bitmap = it, settled = true) } else null,
            cacheKey,
            maybeAnimated,
        ) {
            if (!maybeAnimated) {
                val cached = pictures[cacheKey]
                if (cached != null) {
                    value = source to PictureLoadState(bitmap = cached, settled = true)
                    return@produceState
                }
            }
            value = value?.takeIf { it.first == source }
            val result = try {
                load(attachment, width, height, full)?.let { bytes ->
                    withContext(Dispatchers.Default) {
                        val anim = if (maybeAnimated) decodeAnimated(bytes, width, height) else null
                        if (anim != null) PictureLoadState(animated = anim, settled = true)
                        else PictureLoadState(bitmap = decode(bytes, width, height, full), settled = true)
                    }
                } ?: PictureLoadState(settled = true)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                PictureLoadState(settled = true)
            }
            result.bitmap?.let { pictures.put(cacheKey, it) }
            value = source to result
        }
        state?.takeIf { it.first == source }?.second ?: PictureLoadState()
    }
}

@Composable
private fun AnimatedPictureView(drawable: AnimatedImageDrawable, description: String, modifier: Modifier,
    scaleType: ImageView.ScaleType) {
    AndroidView(
        factory = { context ->
            ImageView(context).apply {
                contentDescription = description
                this.scaleType = scaleType
                setImageDrawable(drawable)
                drawable.start()
            }
        },
        update = { view ->
            view.scaleType = scaleType
            if (view.drawable !== drawable) view.setImageDrawable(drawable)
            if (!drawable.isRunning) drawable.start()
        },
        onRelease = { view ->
            (view.drawable as? AnimatedImageDrawable)?.stop()
            view.setImageDrawable(null)
        },
        modifier = modifier,
    )
}

/**
 * Decodes upright via `ImageDecoder` (honoring EXIF orientation for JPEG/HEIC/WebP), falling back to `SvgDecoder` for
 * SVG payloads and `BitmapFactory` for anything else.
 */
internal fun decode(bytes: ByteArray, width: Int, height: Int, fit: Boolean): ImageBitmap? = try {
    if (SvgDecoder.looksLikeSvg(bytes)) {
        SvgDecoder.decode(bytes, width, height)?.asImageBitmap()
    } else {
        decodeRaster(bytes, width, height, fit)?.asImageBitmap()
    }
} catch (_: OutOfMemoryError) {
    null
}

private fun decodeRaster(bytes: ByteArray, width: Int, height: Int, fit: Boolean): android.graphics.Bitmap? {
    val targetW = max(1, width)
    val targetH = max(1, height)
    val decoded = runCatching {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val w = info.size.width
            val h = info.size.height
            if (w > 0 && h > 0) {
                val scale = if (fit) minOf(targetW.toFloat() / w, targetH.toFloat() / h, 1f)
                else minOf(max(targetW.toFloat() / w, targetH.toFloat() / h), 1f)
                decoder.setTargetSize(max(1, (w * scale).roundToInt()), max(1, (h * scale).roundToInt()))
            }
        }
    }.getOrNull()
    if (decoded != null) return decoded
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val (w, h) = bounds.outWidth to bounds.outHeight
    if (w <= 0 || h <= 0) return null
    val scale = if (fit) minOf(targetW.toFloat() / w, targetH.toFloat() / h, 1f)
    else minOf(max(targetW.toFloat() / w, targetH.toFloat() / h), 1f)
    var sample = 1
    while (w / (sample * 2) >= w * scale && h / (sample * 2) >= h * scale) sample *= 2
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.let {
        val scaledTarget = max(1, (w * scale).roundToInt()) to max(1, (h * scale).roundToInt())
        if (it.width == scaledTarget.first && it.height == scaledTarget.second) it
        else it.scale(scaledTarget.first, scaledTarget.second).also { scaled -> if (scaled !== it) it.recycle() }
    }
}

internal fun decodeAnimated(bytes: ByteArray, width: Int, height: Int): AnimatedImageDrawable? = runCatching {
    if (SvgDecoder.looksLikeSvg(bytes)) return null
    val targetW = max(1, width)
    val targetH = max(1, height)
    val drawable = ImageDecoder.decodeDrawable(ImageDecoder.createSource(ByteBuffer.wrap(bytes))) { decoder, info, _ ->
        val w = info.size.width
        val h = info.size.height
        if (w > 0 && h > 0) {
            val scale = minOf(targetW.toFloat() / w, targetH.toFloat() / h, 1f)
            decoder.setTargetSize(max(1, (w * scale).roundToInt()), max(1, (h * scale).roundToInt()))
        }
    }
    drawable as? AnimatedImageDrawable
}.getOrNull()

/** The box an inline image takes, decided before it loads: its shape within the bounds, never enlarged, as on the Mac. */
internal fun box(width: Int?, height: Int?, maxWidth: Dp, maxHeight: Dp): Pair<Dp, Dp> {
    if (width == null || height == null || width <= 0 || height <= 0) {
        val boxHeight = maxHeight * 3 / 4
        return min(maxWidth, boxHeight * 4 / 3) to boxHeight
    }
    val w = UiMetrics.MediaPixel * width
    val h = UiMetrics.MediaPixel * height
    if (w <= maxWidth && h <= maxHeight) return w to h
    return if (width.toFloat() / height > maxWidth / maxHeight) maxWidth to maxWidth * height / width
    else maxHeight * width / height to maxHeight
}

/** An attachment under its message: an image or video inline, anything else as Slack's file row. A long press opens the message's sheet. */
@Composable
internal fun Attachment(attachment: MessageAttachment, load: PictureLoader, videos: VideoPlayback, opening: Boolean,
    onOpenFile: () -> Unit, onLongPress: () -> Unit, onView: (tile: Pair<Int, Int>) -> Unit) {
    when (attachment.kind) {
        MessageAttachment.Kind.Image -> InlineImage(attachment, load, onLongPress, onView)
        MessageAttachment.Kind.Video -> InlineVideo(attachment, load, videos, onLongPress)
        MessageAttachment.Kind.Audio -> InlineAudio(attachment, videos, onLongPress, onOpenFile)
        else -> FileRow(attachment, opening, onLongPress, onOpenFile)
    }
}

@Composable
private fun InlineImage(attachment: MessageAttachment, load: PictureLoader, onLongPress: () -> Unit, onView: (tile: Pair<Int, Int>) -> Unit) {
    val colors = SlatrixTheme.colors
    val context = LocalContext.current
    val shape = MaterialTheme.shapes.large
    val reducedMotion = kotlin.coroutines.EmptyCoroutineContext.isMotionReduced(context)
    BoxWithConstraints {
        val maxBoxWidth = if (attachment.isSticker) min(maxWidth, UiMetrics.StickerMaxSize) else maxWidth
        val maxBoxHeight = if (attachment.isSticker) UiMetrics.StickerMaxSize else UiMetrics.MediaMaxHeight
        val (width, height) = box(attachment.width, attachment.height, maxBoxWidth, maxBoxHeight)
        val pixels = with(LocalDensity.current) { width.roundToPx() to height.roundToPx() }
        val loaded = pictureState(attachment, pixels.first, pixels.second, false, !reducedMotion, load)
        val hasDimensions = !attachment.isSticker && attachment.width != null && attachment.height != null
        val surface = if (attachment.isSticker) Modifier.size(width, height).clip(shape)
        else Modifier.size(width, height).clip(shape).background(colors.sunken)
        Box(surface
            .semantics { contentDescription = attachment.name }
            .combinedClickable(onClickLabel = "View image", onLongClickLabel = "Message actions", onLongClick = onLongPress) { onView(pixels) },
            contentAlignment = Alignment.Center) {
            when {
                loaded.animated != null -> AnimatedPictureView(
                    loaded.animated, attachment.name, Modifier.fillMaxSize(),
                    if (hasDimensions) ImageView.ScaleType.CENTER_CROP else ImageView.ScaleType.FIT_CENTER,
                )
                loaded.bitmap != null -> {
                    val scale = if (hasDimensions) ContentScale.Crop else ContentScale.Fit
                    Image(loaded.bitmap, null, Modifier.fillMaxSize(), contentScale = scale)
                }
                loaded.settled -> {
                    Column(
                        Modifier.padding(UiMetrics.GapLarge),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny),
                    ) {
                        Icon(Icons.Outlined.Image, null, Modifier.size(UiMetrics.LargeIcon), tint = colors.textSecondary)
                        Text(attachment.name, style = MaterialTheme.typography.bodySmall, color = colors.textSecondary,
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        attachment.size?.let {
                            Text(Formatter.formatShortFileSize(context, it), style = MaterialTheme.typography.labelSmall,
                                color = colors.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

/** Slack's file row: a tile colored by the file's kind, its name and its type and size. A tap downloads and opens it. */
@Composable
private fun FileRow(attachment: MessageAttachment, opening: Boolean, onLongPress: () -> Unit, onOpen: () -> Unit) {
    val colors = SlatrixTheme.colors
    val context = LocalContext.current
    val kind = remember(attachment) { FileKind.of(attachment.name, attachment.mimeType) }
    val details = remember(attachment) {
        listOfNotNull(kind.label(attachment.name), attachment.size?.let { Formatter.formatShortFileSize(context, it) }).joinToString(" · ")
    }
    val shape = MaterialTheme.shapes.large
    // Straight on the bubble, as a messenger sets a file, without a card of its own.
    Row(Modifier.clip(shape)
        .combinedClickable(onClickLabel = "Open file", onLongClickLabel = "Message actions", onLongClick = onLongPress) { if (!opening) onOpen() }
        .padding(vertical = UiMetrics.GapTiny),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically) {
        FileTile(kind)
        Column(Modifier.weight(1f)) {
            Text(attachment.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, color = colors.textPrimary,
                maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            Text(details, style = MaterialTheme.typography.bodyMedium, color = colors.textSecondary, maxLines = 1)
        }
        // Its space is always there, so the row never moves when the progress shows.
        Box(Modifier.size(UiMetrics.Icon)) {
            var late by remember { mutableStateOf(false) }
            LaunchedEffect(opening) { late = false; if (opening) { delay(UiMetrics.ProgressDelayMillis); late = true } }
            if (opening && late) CircularProgressIndicator(Modifier.fillMaxSize())
        }
    }
}

/** A file's tile: a soft tinted container with a crisp icon in its kind's color (or high-contrast white on outgoing bubbles). */
@Composable
internal fun FileTile(kind: FileKind) {
    val colors = SlatrixTheme.colors
    val fileColor = DesignTokens.fileColors.getValue(kind.token)
    Box(Modifier.size(UiMetrics.FileTile).background(colors.fileTileFill(fileColor), MaterialTheme.shapes.medium),
        contentAlignment = Alignment.Center) {
        Icon(Icons.Outlined.Description, null, Modifier.size(UiMetrics.Icon), tint = colors.fileTileIcon(fileColor))
    }
}

private val OffsetSaver = Saver<Offset, List<Float>>({ listOf(it.x, it.y) }, { Offset(it[0], it[1]) })

/**
 * An image full screen on black, as in Slack: pinch or double-tap to zoom, drag to look around, Close to leave, with who
 * sent it and when, and Share and Save to device once [loadFile] can download it. Until the image loads, the picture its
 * [tile] showed holds the image's box; one already loaded shows at once.
 */
@Composable
internal fun MediaViewer(attachment: MessageAttachment, tile: Pair<Int, Int>, load: PictureLoader, sender: String, timestamp: Long,
    loadFile: FileLoader?, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var notice by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(notice) { if (notice != null) { delay(UiMetrics.NoticeMillis); notice = null } }
    // Saved with the screen rather than in the dialog, whose window keeps its saved state apart.
    var scale by rememberSaveable { mutableFloatStateOf(1f) }
    var offset by rememberSaveable(stateSaver = OffsetSaver) { mutableStateOf(Offset.Zero) }
    val currentDismiss by rememberUpdatedState(onDismiss)
    val enter = remember { Animatable(0f) }
    val dismissDrag = remember { Animatable(0f) }
    var dismissing by remember { mutableStateOf(false) }
    fun withFile(action: suspend (File) -> String?) {
        if (dismissing) return
        val files = loadFile ?: return
        scope.launch {
            val file = try { files(attachment) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
            if (dismissing) return@launch
            notice = if (file == null) "Couldn’t download ${attachment.name}." else try {
                action(file)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                "Couldn’t save ${attachment.name}."
            }
        }
    }
    fun closeSmoothly() {
        if (dismissing) return
        dismissing = true
        scope.launch {
            if (!coroutineContext.isMotionReduced(context)) enter.animateTo(0f, Motion.gentle(Motion.UnitThreshold))
            currentDismiss()
        }
    }
    Dialog({ closeSmoothly() }, DialogProperties(usePlatformDefaultWidth = false)) {
        LaunchedEffect(enter) {
            if (coroutineContext.isMotionReduced(context)) enter.snapTo(1f)
            else enter.animateTo(1f, Motion.spatial(Motion.UnitThreshold))
        }
        val reducedMotion = kotlin.coroutines.EmptyCoroutineContext.isMotionReduced(context)
        val fullState = pictureState(attachment, UiMetrics.ViewerPixels, UiMetrics.ViewerPixels, true, !reducedMotion, load)
        val full = fullState.bitmap
        val animatedFull = fullState.animated
        val placeholder = if (full == null && animatedFull == null) picture(attachment, tile.first, tile.second, false, load) else null
        var size by remember { mutableStateOf(IntSize.Zero) }
        val dismissReach = with(LocalDensity.current) { UiMetrics.ViewerDismiss.toPx() }
        val dismissFlick = with(LocalDensity.current) { UiMetrics.SheetDismissVelocity.toPx() }
        // Zoomed in, the picture moves only as far as its edges.
        fun bounded(value: Offset): Offset {
            val x = size.width * (scale - 1) / 2
            val y = size.height * (scale - 1) / 2
            return Offset(value.x.coerceIn(-x, x), value.y.coerceIn(-y, y))
        }
        fun dragProgress(): Float =
            if (size.height > 0) (abs(dismissDrag.value) / (size.height * 0.5f)).coerceIn(0f, 1f) else 0f
        BoxWithConstraints(Modifier.fillMaxSize()
            .then(if (dismissing) Modifier.clearAndSetSemantics {}.focusProperties { canFocus = false }.pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
                }
            } else Modifier)
            .drawBehind {
                val alpha = (1f - dragProgress()) * enter.value.coerceIn(0f, 1f)
                if (alpha > 0f) drawRect(colors.mediaBackdrop, alpha = alpha)
            }.onSizeChanged { size = it }) {
            // The image's box fitted to the screen, from its size in the event; unknown, the small picture isn't stretched.
            val (w, h) = (attachment.width ?: 0) to (attachment.height ?: 0)
            val fit = if (w > 0 && h > 0) minOf(maxWidth / w, maxHeight / h) else null
            Box(Modifier.fillMaxSize()
                .pointerInput(dismissReach, dismissFlick) {
                    val slop = viewConfiguration.touchSlop
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        if (dismissing) return@awaitEachGesture
                        val velocityTracker = VelocityTracker()
                        var totalPan = Offset.Zero
                        var currentDrag = dismissDrag.value
                        var draggingDismiss = false
                        var transforming = false
                        var cancelled = false
                        do {
                            val event = awaitPointerEvent()
                            if (dismissing) {
                                cancelled = true
                                break
                            }
                            val active = event.changes.filter { it.pressed }
                            if (active.isEmpty()) {
                                val up = event.changes.firstOrNull()
                                // ACTION_CANCEL arrives as a consumed synthetic up; treat it as cancel rather than release,
                                // and feed genuine up timestamps to VelocityTracker so pausing before lifting zeros velocity.
                                if (up == null || up.isConsumed || !up.changedToUp()) {
                                    cancelled = true
                                } else if (draggingDismiss) {
                                    velocityTracker.addPosition(up.uptimeMillis, up.position)
                                }
                                break
                            }
                            val zoom = event.calculateZoom()
                            val pan = event.calculatePan()
                            if (active.size > 1 || zoom != 1f || scale > 1f || transforming) {
                                transforming = true
                                if (draggingDismiss) {
                                    draggingDismiss = false
                                    currentDrag = 0f
                                    scope.launch { dismissDrag.snapTo(0f) }
                                }
                                scale = (scale * zoom).coerceIn(1f, UiMetrics.ViewerMaxZoom)
                                offset = bounded(offset + pan)
                                if (active.size > 1 || abs(pan.x) > 0f || abs(pan.y) > 0f) {
                                    event.changes.forEach { it.consume() }
                                }
                            } else {
                                totalPan += pan
                                if (!draggingDismiss && abs(totalPan.y) > slop && abs(totalPan.y) > abs(totalPan.x)) {
                                    draggingDismiss = true
                                }
                                if (draggingDismiss) {
                                    val pointer = active.first()
                                    velocityTracker.addPosition(pointer.uptimeMillis, pointer.position)
                                    currentDrag += pan.y
                                    val snapped = currentDrag
                                    scope.launch { dismissDrag.snapTo(snapped) }
                                    event.changes.forEach { it.consume() }
                                }
                            }
                        } while (event.changes.any { it.pressed })
                        if (draggingDismiss && !dismissing) {
                            val vy = if (cancelled) 0f else velocityTracker.calculateVelocity().y
                            val distance = currentDrag
                            val shouldDismiss = !cancelled && (abs(distance) > dismissReach ||
                                (abs(distance) > 0f && abs(vy) > dismissFlick && sign(vy) == sign(distance)))
                            if (shouldDismiss) {
                                dismissing = true
                                val exitTarget = (if (distance >= 0f) 1f else -1f) * max(size.height.toFloat(), dismissReach * 2f)
                                scope.launch {
                                    if (!coroutineContext.isMotionReduced(context)) {
                                        dismissDrag.animateTo(exitTarget, Motion.gentle(Motion.PixelThreshold), initialVelocity = vy)
                                    }
                                    currentDismiss()
                                }
                            } else {
                                scope.launch {
                                    if (coroutineContext.isMotionReduced(context)) dismissDrag.snapTo(0f)
                                    else dismissDrag.animateTo(0f, Motion.snappy(Motion.PixelThreshold), initialVelocity = vy)
                                }
                            }
                        }
                    }
                }
                .pointerInput(Unit) {
                    detectTapGestures(onDoubleTap = {
                        if (dismissing) return@detectTapGestures
                        scale = if (scale > 1f) 1f else UiMetrics.ViewerDoubleTapZoom
                        offset = Offset.Zero
                        if (dismissDrag.value != 0f) scope.launch { dismissDrag.snapTo(0f) }
                    })
                }
                .graphicsLayer {
                    val dragScale = 1f - 0.18f * dragProgress()
                    val enterScale = 0.92f + 0.08f * enter.value
                    scaleX = scale * dragScale * enterScale
                    scaleY = scale * dragScale * enterScale
                    translationX = offset.x
                    translationY = offset.y + dismissDrag.value
                    alpha = enter.value.coerceIn(0f, 1f)
                },
                contentAlignment = Alignment.Center) {
                when {
                    animatedFull != null -> AnimatedPictureView(
                        animatedFull, attachment.name, Modifier.fillMaxSize(), ImageView.ScaleType.FIT_CENTER)
                    full != null -> Image(full, attachment.name, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                    placeholder != null && fit != null ->
                        Image(placeholder, attachment.name, Modifier.size(fit * w, fit * h), contentScale = ContentScale.Crop)
                    placeholder != null ->
                        Image(placeholder, attachment.name, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                }
            }
            Row(Modifier.fillMaxWidth()
                .graphicsLayer { alpha = ((1f - dragProgress() * 2.5f) * enter.value).coerceIn(0f, 1f) }
                .background(colors.mediaShade).statusBarsPadding(), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = ::closeSmoothly, enabled = !dismissing) { Icon(Icons.Outlined.Close, "Close", tint = colors.onMedia) }
                Column(Modifier.weight(1f)) {
                    Text(sender, style = MaterialTheme.typography.titleSmall, color = colors.onMedia, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
                    Text("${dayLabel(timestamp)} at ${timeLabel(timestamp)}", style = MaterialTheme.typography.bodySmall,
                        color = colors.onMedia, maxLines = 1)
                }
                if (loadFile != null) {
                    IconButton(onClick = { withFile { shareFile(context, it, attachment); null } }, enabled = !dismissing) {
                        Icon(Icons.Outlined.Share, "Share", tint = colors.onMedia)
                    }
                    IconButton(onClick = { withFile { saveFile(context, it, attachment) } }, enabled = !dismissing) {
                        Icon(Icons.Outlined.FileDownload, "Save to device", tint = colors.onMedia)
                    }
                }
            }
            notice?.let {
                Text(it, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(UiMetrics.GapLarge)
                    .background(colors.mediaShade, MaterialTheme.shapes.extraLarge)
                    .padding(horizontal = UiMetrics.GapLarge, vertical = UiMetrics.GapSmall),
                    style = MaterialTheme.typography.bodyMedium, color = colors.onMedia)
            }
        }
    }
}
