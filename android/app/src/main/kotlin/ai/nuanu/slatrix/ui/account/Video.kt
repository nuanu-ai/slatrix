package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/** A file's whole contents on this phone, once downloaded; null when it can't be. */
typealias FileLoader = suspend (MessageAttachment) -> File?

/** "1:23", or "1:02:03" past an hour, as a video's poster shows its length. */
internal fun durationLabel(millis: Long): String {
    val seconds = millis / 1_000
    val (hours, minutes) = seconds / 3_600 to seconds / 60 % 60
    return if (hours > 0) "%d:%02d:%02d".format(hours, minutes, seconds % 60) else "%d:%02d".format(minutes, seconds % 60)
}

/**
 * A video in its message, in the box its event's size reserves: the sender's poster with its length, then a tap plays
 * it in place, and a tap while it plays opens it full screen.
 */
@Composable
internal fun InlineVideo(attachment: MessageAttachment, load: PictureLoader, loadFile: FileLoader, onLongPress: () -> Unit) {
    val colors = SlatrixTheme.colors
    val shape = MaterialTheme.shapes.large
    val context = LocalContext.current
    var asked by remember(attachment.source.url()) { mutableStateOf(false) }
    var player by remember(attachment.source.url()) { mutableStateOf<ExoPlayer?>(null) }
    var full by remember { mutableStateOf(false) }
    LaunchedEffect(asked) {
        if (!asked) return@LaunchedEffect
        val file = try { loadFile(attachment) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
        // A file that can't be fetched leaves the poster, ready to try again.
        if (file == null) asked = false
        else player = ExoPlayer.Builder(context).build().apply {
            setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
            prepare()
            playWhenReady = true
        }
    }
    DisposableEffect(player) { onDispose { player?.release() } }
    PauseInBackground(player)
    BoxWithConstraints(Modifier.padding(top = UiMetrics.GapTiny).fillMaxWidth()) {
        val (width, height) = box(attachment.width, attachment.height, maxWidth, UiMetrics.MediaMaxHeight)
        val pixels = with(LocalDensity.current) { width.roundToPx() to height.roundToPx() }
        val poster = picture(attachment, pixels.first, pixels.second, false, load)
        Box(Modifier.size(width, height).clip(shape).background(colors.sunken).border(UiMetrics.Divider, colors.border, shape)) {
            val playing = player
            if (playing != null && !full) AndroidView({ PlayerView(it).apply { useController = false } }, Modifier.fillMaxSize(),
                update = { it.player = playing }, onRelease = { it.player = null })
            else poster?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
            if (playing == null) {
                Box(Modifier.align(Alignment.Center).size(UiMetrics.Touch).background(colors.mediaShade, CircleShape),
                    contentAlignment = Alignment.Center) {
                    if (asked) DelayedSpinner() else Icon(Icons.Filled.PlayArrow, null, tint = colors.onMedia)
                }
                attachment.durationMillis?.let {
                    Text(durationLabel(it), Modifier.align(Alignment.BottomStart).padding(UiMetrics.GapSmall)
                        .background(colors.mediaShade, MaterialTheme.shapes.small).padding(horizontal = UiMetrics.GapTiny),
                        style = MaterialTheme.typography.labelMedium, color = colors.onMedia)
                }
            }
            // Over the player, which as a view would take the taps itself.
            Box(Modifier.matchParentSize().semantics { contentDescription = attachment.name }.combinedClickable(onClickLabel = if (playing == null) "Play video" else "Full screen",
                onLongClick = onLongPress) { if (playing == null) asked = true else full = true })
        }
    }
    player?.takeIf { full }?.let { VideoViewer(attachment, it) { full = false } }
}

@Composable
private fun DelayedSpinner() {
    var late by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { delay(UiMetrics.ProgressDelayMillis); late = true }
    if (late) CircularProgressIndicator(Modifier.size(UiMetrics.Icon), color = SlatrixTheme.colors.onMedia)
}

/** Leaving the app pauses what plays, as Slack does. */
@Composable
private fun PauseInBackground(player: Player?) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, player) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_PAUSE) player?.pause() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
}

/** A video full screen on black with the player's controls, carrying on from where it played in the row. */
@Composable
private fun VideoViewer(attachment: MessageAttachment, player: Player, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(colors.mediaBackdrop)) {
            AndroidView({ PlayerView(it) }, Modifier.fillMaxSize(), update = { it.player = player }, onRelease = { it.player = null })
            Row(Modifier.fillMaxWidth().statusBarsPadding().background(colors.mediaShade).padding(end = UiMetrics.GapLarge),
                verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onDismiss) { Icon(Icons.Outlined.Close, "Close", tint = colors.onMedia) }
                Text(attachment.name, style = MaterialTheme.typography.titleSmall, color = colors.onMedia, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
