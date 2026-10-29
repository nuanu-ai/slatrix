package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.FileKind
import ai.nuanu.slatrix.core.MatrixMedia
import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.ui.designsystem.DesignTokens
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.core.graphics.scale
import android.graphics.BitmapFactory
import android.text.format.Formatter
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
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
    val type = attachment.mimeType ?: context.contentResolver.getType(uri) ?: "*/*"
    return try {
        context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK))
        null
    } catch (_: ActivityNotFoundException) {
        "No app on this phone opens ${attachment.name}."
    }
}

/** Fetches a picture of an attachment no bigger than the pixels asked for; [full] asks for the original, for the viewer. */
typealias PictureLoader = suspend (MessageAttachment, width: Int, height: Int, full: Boolean) -> ByteArray?

/** Decoded pictures, shared by every conversation, so scrolling back or reopening a room shows them at once. */
private val pictures = object : LruCache<String, ImageBitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
    override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
}

/**
 * The picture, decoded off the main thread to exactly the size asked for: filling it inline, or fitting inside it
 * full screen. Null while it loads or when there's none.
 */
@Composable
private fun picture(attachment: MessageAttachment, width: Int, height: Int, full: Boolean, load: PictureLoader): ImageBitmap? {
    val key = "${attachment.source.url()}@${width}x$height${if (full) " full" else ""}"
    val picture by produceState(pictures[key], key) {
        if (value != null) return@produceState
        value = try {
            load(attachment, width, height, full)?.let { bytes -> withContext(Dispatchers.Default) { decode(bytes, width, height, full) } }
                ?.also { pictures.put(key, it) }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // The box stays empty; a broken picture never moves the row.
            null
        }
    }
    return picture
}

/**
 * Decodes at the largest power-of-two step down that is still bigger than needed, then scales to size, so an encrypted
 * original, which arrives whole, never sits in memory at full size.
 */
internal fun decode(bytes: ByteArray, width: Int, height: Int, fit: Boolean): ImageBitmap? = try {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    val (w, h) = bounds.outWidth to bounds.outHeight
    // Filling a box needs the scale of its tighter side, fitting in one the scale of its looser side.
    val scale = if (fit) minOf(width.toFloat() / w, height.toFloat() / h, 1f) else minOf(max(width.toFloat() / w, height.toFloat() / h), 1f)
    var sample = 1
    while (w / (sample * 2) >= w * scale && h / (sample * 2) >= h * scale) sample *= 2
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.let {
        val target = max(1, (w * scale).roundToInt()) to max(1, (h * scale).roundToInt())
        if (it.width == target.first && it.height == target.second) it
        else it.scale(target.first, target.second).also { scaled -> if (scaled !== it) it.recycle() }
    }?.asImageBitmap()
} catch (_: OutOfMemoryError) {
    null
}

/** The box an inline image takes, decided before it loads: its shape within the bounds, never enlarged, as on the Mac. */
private fun box(width: Int?, height: Int?, maxWidth: Dp, maxHeight: Dp): Pair<Dp, Dp> {
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

/** An attachment under its message: an image inline, anything else as Slack's file row. */
@Composable
internal fun Attachment(attachment: MessageAttachment, load: PictureLoader, opening: Boolean, onOpenFile: () -> Unit,
    onView: (ImageBitmap?) -> Unit) {
    if (attachment.kind == MessageAttachment.Kind.Image) InlineImage(attachment, load, onView) else FileRow(attachment, opening, onOpenFile)
}

@Composable
private fun InlineImage(attachment: MessageAttachment, load: PictureLoader, onView: (ImageBitmap?) -> Unit) {
    val colors = SlatrixTheme.colors
    val shape = MaterialTheme.shapes.large
    BoxWithConstraints(Modifier.padding(top = UiMetrics.GapTiny).fillMaxWidth()) {
        val (width, height) = box(attachment.width, attachment.height, maxWidth, UiMetrics.MediaMaxHeight)
        val pixels = with(LocalDensity.current) { width.roundToPx() to height.roundToPx() }
        val shown = picture(attachment, pixels.first, pixels.second, false, load)
        Box(Modifier.size(width, height).clip(shape).background(colors.sunken).border(UiMetrics.Divider, colors.border, shape)
            .semantics { contentDescription = attachment.name }.clickable(onClickLabel = "View image") { onView(shown) }) {
            shown?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        }
    }
}

/** Slack's file row: a tile colored by the file's kind, its name and its type and size. A tap downloads and opens it. */
@Composable
private fun FileRow(attachment: MessageAttachment, opening: Boolean, onOpen: () -> Unit) {
    val colors = SlatrixTheme.colors
    val context = LocalContext.current
    val kind = remember(attachment) { FileKind.of(attachment.name, attachment.mimeType) }
    val details = remember(attachment) {
        listOfNotNull(kind.label(attachment.name), attachment.size?.let { Formatter.formatShortFileSize(context, it) }).joinToString(" · ")
    }
    val shape = MaterialTheme.shapes.large
    Row(Modifier.padding(top = UiMetrics.GapTiny).fillMaxWidth().clip(shape).border(UiMetrics.Divider, colors.border, shape)
        .clickable(enabled = !opening, onClickLabel = "Open file", onClick = onOpen).padding(UiMetrics.GapMedium),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically) {
        FileTile(kind)
        Column(Modifier.weight(1f)) {
            Text(attachment.name, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Bold, color = colors.textPrimary,
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

/** A file's tile, in its kind's color, as file rows and the Files list show it. */
@Composable
internal fun FileTile(kind: FileKind) {
    Box(Modifier.size(UiMetrics.FileTile).background(DesignTokens.fileColors.getValue(kind.token), MaterialTheme.shapes.medium),
        contentAlignment = Alignment.Center) {
        Icon(Icons.Outlined.Description, null, Modifier.size(UiMetrics.Icon), tint = SlatrixTheme.colors.onAccent)
    }
}

/** An image full screen on black, as in Slack: pinch or double-tap to zoom, drag to look around, Close to leave. */
@Composable
internal fun MediaViewer(attachment: MessageAttachment, placeholder: ImageBitmap?, load: PictureLoader, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        val full = picture(attachment, UiMetrics.ViewerPixels, UiMetrics.ViewerPixels, true, load)
        var scale by remember { mutableFloatStateOf(1f) }
        var offset by remember { mutableStateOf(Offset.Zero) }
        var size by remember { mutableStateOf(IntSize.Zero) }
        // Zoomed in, the picture moves only as far as its edges.
        fun bounded(value: Offset): Offset {
            val x = size.width * (scale - 1) / 2
            val y = size.height * (scale - 1) / 2
            return Offset(value.x.coerceIn(-x, x), value.y.coerceIn(-y, y))
        }
        Box(Modifier.fillMaxSize().background(colors.mediaBackdrop).onSizeChanged { size = it }) {
            (full ?: placeholder)?.let {
                Image(it, attachment.name, Modifier.fillMaxSize()
                    .pointerInput(Unit) {
                        detectTransformGestures { _, pan, zoom, _ ->
                            scale = (scale * zoom).coerceIn(1f, UiMetrics.ViewerMaxZoom)
                            offset = bounded(offset + pan)
                        }
                    }
                    .pointerInput(Unit) {
                        detectTapGestures(onDoubleTap = { scale = if (scale > 1f) 1f else UiMetrics.ViewerDoubleTapZoom; offset = Offset.Zero })
                    }
                    .graphicsLayer(scaleX = scale, scaleY = scale, translationX = offset.x, translationY = offset.y),
                    contentScale = ContentScale.Fit)
            }
            Row(Modifier.fillMaxWidth().statusBarsPadding().background(colors.mediaShade).padding(end = UiMetrics.GapLarge),
                verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onDismiss) { Icon(Icons.Outlined.Close, "Close", tint = colors.onMedia) }
                Text(attachment.name, style = MaterialTheme.typography.titleSmall, color = colors.onMedia, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
