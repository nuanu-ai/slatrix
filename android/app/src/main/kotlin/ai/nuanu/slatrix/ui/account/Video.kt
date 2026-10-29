package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.content.Context
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
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
import kotlinx.coroutines.launch

/** A file's whole contents on this phone, once downloaded; null when it can't be. */
typealias FileLoader = suspend (MessageAttachment) -> File?

/** "1:23", or "1:02:03" past an hour, as a video's poster shows its length. */
internal fun durationLabel(millis: Long): String {
    val seconds = millis / 1_000
    val (hours, minutes) = seconds / 3_600 to seconds / 60 % 60
    return if (hours > 0) "%d:%02d:%02d".format(hours, minutes, seconds % 60) else "%d:%02d".format(minutes, seconds % 60)
}

/**
 * The conversation's one player, so starting a video stops the one before, as in Slack. Its videos are fetched whole
 * through [loadFile], the SDK's media store, which decrypts them.
 */
internal class VideoPlayback(private val context: Context, private val loadFile: FileLoader) {
    /** The source of the video in the player, and of the one being fetched for it. */
    var playing by mutableStateOf<String?>(null)
        private set
    var fetching by mutableStateOf<String?>(null)
        private set
    private var exo: ExoPlayer? = null
    val player: Player? get() = exo

    suspend fun start(attachment: MessageAttachment) {
        val key = attachment.source.url()
        fetching = key
        val file = try { loadFile(attachment) } catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
        // Another video asked for meanwhile wins; one that can't be fetched leaves its poster, ready to try again.
        if (fetching != key) return
        fetching = null
        if (file == null) return
        (exo ?: ExoPlayer.Builder(context).build().also { exo = it }).run {
            setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
            prepare()
            playWhenReady = true
        }
        playing = key
    }

    fun stop(key: String) {
        if (playing != key) return
        exo?.stop()
        playing = null
    }

    fun pause() = exo?.pause()

    fun release() {
        exo?.release()
        exo = null
        playing = null
    }
}

/** The conversation's player, released when it closes and paused while the app is in the background. */
@Composable
internal fun rememberVideoPlayback(loadFile: FileLoader): VideoPlayback {
    val context = LocalContext.current
    val files by rememberUpdatedState(loadFile)
    val playback = remember { VideoPlayback(context.applicationContext) { files(it) } }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(playback, lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_PAUSE) playback.pause() }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            playback.release()
        }
    }
    return playback
}

/**
 * A video in its message, in the box its event's size reserves: the sender's poster with its length, then a tap plays
 * it in place, and a tap while it plays opens it full screen.
 */
@Composable
internal fun InlineVideo(attachment: MessageAttachment, load: PictureLoader, videos: VideoPlayback, onLongPress: () -> Unit) {
    val colors = SlatrixTheme.colors
    val shape = MaterialTheme.shapes.large
    val scope = rememberCoroutineScope()
    val key = attachment.source.url()
    val player = videos.player.takeIf { videos.playing == key }
    var full by remember { mutableStateOf(false) }
    // A video scrolled away stops, as its row is gone.
    DisposableEffect(videos, key) { onDispose { videos.stop(key) } }
    BoxWithConstraints(Modifier.padding(top = UiMetrics.GapTiny).fillMaxWidth()) {
        val (width, height) = box(attachment.width, attachment.height, maxWidth, UiMetrics.MediaMaxHeight)
        val pixels = with(LocalDensity.current) { width.roundToPx() to height.roundToPx() }
        val poster = picture(attachment, pixels.first, pixels.second, false, load)
        Box(Modifier.size(width, height).clip(shape).background(colors.sunken).border(UiMetrics.Divider, colors.border, shape)) {
            if (player != null && !full) AndroidView({ PlayerView(it).apply { useController = false } }, Modifier.fillMaxSize(),
                update = { it.player = player }, onRelease = { it.player = null })
            else poster?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
            if (player == null) {
                Box(Modifier.align(Alignment.Center).size(UiMetrics.Touch).background(colors.mediaShade, CircleShape),
                    contentAlignment = Alignment.Center) {
                    if (videos.fetching == key) DelayedSpinner() else Icon(Icons.Filled.PlayArrow, null, tint = colors.onMedia)
                }
                attachment.durationMillis?.let {
                    Text(durationLabel(it), Modifier.align(Alignment.BottomStart).padding(UiMetrics.GapSmall)
                        .background(colors.mediaShade, MaterialTheme.shapes.small).padding(horizontal = UiMetrics.GapTiny),
                        style = MaterialTheme.typography.labelMedium, color = colors.onMedia)
                }
            }
            // Over the player, which as a view would take the taps itself.
            Box(Modifier.matchParentSize().semantics { contentDescription = attachment.name }
                .combinedClickable(onClickLabel = if (player == null) "Play video" else "Full screen",
                    onLongClickLabel = "Message actions", onLongClick = onLongPress) {
                    if (player != null) full = true else scope.launch { videos.start(attachment) }
                })
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
