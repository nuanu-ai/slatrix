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
import android.graphics.BitmapFactory
import android.text.format.Formatter
import android.util.LruCache
import android.widget.Toast
import androidx.core.content.FileProvider
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
import androidx.compose.runtime.rememberCoroutineScope
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.min
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Downloads the file and hands it to the app the phone opens its kind with, as Slack does. */
internal suspend fun openAttachment(context: Context, media: MatrixMedia, attachment: MessageAttachment): String? {
    val file = try {
        media.file(attachment)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        Toast.makeText(context, "Couldn’t download ${attachment.name}.", Toast.LENGTH_SHORT).show()
        return null
    }
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    val type = attachment.mimeType ?: context.contentResolver.getType(uri) ?: "*/*"
    try {
        context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, type).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    } catch (_: ActivityNotFoundException) {
        Toast.makeText(context, "No app on this phone opens ${attachment.name}.", Toast.LENGTH_SHORT).show()
    }
    return null
}

/** Fetches a picture of an attachment no bigger than the pixels asked for. */
typealias PictureLoader = suspend (MessageAttachment, width: Int, height: Int, full: Boolean) -> ByteArray?

/** Decoded pictures, shared by every conversation, so scrolling back or reopening a room shows them at once. */
private val pictures = object : LruCache<String, ImageBitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
    override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
}

/** The picture, decoded off the main thread at no more than the size asked for, or null when there's none. */
@Composable
private fun picture(attachment: MessageAttachment, width: Int, height: Int, load: PictureLoader): ImageBitmap? {
    val key = "${(attachment.thumbnail ?: attachment.source).url()}@${width}x$height"
    val picture by produceState(pictures[key], key) {
        if (value != null) return@produceState
        value = try {
            load(attachment, width, height, false)?.let { bytes -> withContext(Dispatchers.Default) { decode(bytes, width, height) } }
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

/** Decodes at the largest power-of-two step down that still covers the size, since an encrypted original arrives whole. */
private fun decode(bytes: ByteArray, width: Int, height: Int): ImageBitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    var sample = 1
    while (bounds.outWidth / (sample * 2) >= width && bounds.outHeight / (sample * 2) >= height) sample *= 2
    return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
        ?.asImageBitmap()
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
internal fun Attachment(attachment: MessageAttachment, load: PictureLoader, onOpenFile: suspend (MessageAttachment) -> String?,
    onView: (ImageBitmap?) -> Unit) {
    if (attachment.kind == MessageAttachment.Kind.Image) InlineImage(attachment, load, onView) else FileRow(attachment, onOpenFile)
}

@Composable
private fun InlineImage(attachment: MessageAttachment, load: PictureLoader, onView: (ImageBitmap?) -> Unit) {
    val colors = SlatrixTheme.colors
    val shape = MaterialTheme.shapes.large
    BoxWithConstraints(Modifier.padding(top = UiMetrics.GapTiny).fillMaxWidth()) {
        val (width, height) = box(attachment.width, attachment.height, maxWidth, UiMetrics.MediaMaxHeight)
        val pixels = with(LocalDensity.current) { width.roundToPx() to height.roundToPx() }
        val shown = picture(attachment, pixels.first, pixels.second, load)
        Box(Modifier.size(width, height).clip(shape).background(colors.sunken).border(UiMetrics.Divider, colors.border, shape)
            .semantics { contentDescription = attachment.name }.clickable(onClickLabel = "View image") { onView(shown) }) {
            shown?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
        }
    }
}

/** Slack's file row: a tile colored by the file's kind, its name and its type and size. A tap downloads and opens it. */
@Composable
private fun FileRow(attachment: MessageAttachment, onOpen: suspend (MessageAttachment) -> String?) {
    val colors = SlatrixTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var opening by remember { mutableStateOf(false) }
    val kind = remember(attachment) { FileKind.of(attachment.name, attachment.mimeType) }
    val details = remember(attachment) {
        listOfNotNull(FileKind.label(attachment.name, kind), attachment.size?.let { Formatter.formatShortFileSize(context, it) })
            .joinToString(" · ")
    }
    val shape = MaterialTheme.shapes.large
    Row(Modifier.padding(top = UiMetrics.GapTiny).fillMaxWidth().clip(shape).border(UiMetrics.Divider, colors.border, shape)
        .clickable(enabled = !opening, onClickLabel = "Open file") {
            scope.launch { opening = true; try { onOpen(attachment) } finally { opening = false } }
        }.padding(UiMetrics.GapMedium),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(UiMetrics.Avatar).background(DesignTokens.fileColors.getValue(kind.token), MaterialTheme.shapes.medium),
            contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.Description, null, Modifier.size(UiMetrics.Icon), tint = colors.onAccent)
        }
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

/** An image full screen on black, as in Slack: pinch or double-tap to zoom, drag to look around, Close to leave. */
@Composable
internal fun MediaViewer(attachment: MessageAttachment, placeholder: ImageBitmap?, load: PictureLoader, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        val full = picture(attachment, UiMetrics.ViewerPixels, UiMetrics.ViewerPixels, load)
        var scale by remember { mutableFloatStateOf(1f) }
        var offset by remember { mutableStateOf(Offset.Zero) }
        Box(Modifier.fillMaxSize().background(colors.mediaBackdrop)) {
            (full ?: placeholder)?.let {
                Image(it, attachment.name, Modifier.fillMaxSize()
                    .pointerInput(Unit) {
                        detectTransformGestures { _, pan, zoom, _ ->
                            scale = (scale * zoom).coerceIn(1f, UiMetrics.ViewerMaxZoom)
                            offset = if (scale == 1f) Offset.Zero else offset + pan
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
