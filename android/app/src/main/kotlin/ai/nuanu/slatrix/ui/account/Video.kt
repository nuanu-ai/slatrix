package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.R
import ai.nuanu.slatrix.core.FileKind
import ai.nuanu.slatrix.core.MessageAttachment
import ai.nuanu.slatrix.ui.designsystem.SlatrixTheme
import ai.nuanu.slatrix.ui.designsystem.UiMetrics
import android.content.Context
import android.net.Uri
import android.text.format.Formatter
import android.view.LayoutInflater
import android.widget.FrameLayout
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.FileDownload
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** A file's whole contents on this phone, once downloaded; null when it can't be. */
typealias FileLoader = suspend (MessageAttachment) -> File?

/** "1:23", or "1:02:03" past an hour, as a video's poster or audio clip shows its length. */
internal fun durationLabel(millis: Long): String {
    val seconds = maxOf(0L, millis) / 1_000
    val (hours, minutes) = seconds / 3_600 to seconds / 60 % 60
    return if (hours > 0) "%d:%02d:%02d".format(hours, minutes, seconds % 60) else "%d:%02d".format(minutes, seconds % 60)
}

/**
 * The conversation's one player for video and audio, so starting any clip stops the one before, as in Slack.
 * Its media is fetched whole through [loadFile], the SDK's media store, which decrypts it.
 */
internal class VideoPlayback(private val context: Context, private val loadFile: FileLoader) {
    /** The source of the media in the player, and of the one being fetched for it. */
    var playing by mutableStateOf<String?>(null)
        private set
    var playingKind by mutableStateOf<MessageAttachment.Kind?>(null)
        private set
    var fetching by mutableStateOf<String?>(null)
        private set
    var isActive by mutableStateOf(false)
        private set
    var positionMillis by mutableLongStateOf(0L)
        private set
    var durationMillis by mutableLongStateOf(0L)
        private set
    var errorKey by mutableStateOf<String?>(null)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    private var exo: ExoPlayer? = null
    private val files = LinkedHashMap<String, File>()
    val player: Player? get() = exo

    private val listener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            isActive = isPlaying
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            val current = exo ?: return
            if (current.duration > 0L) durationMillis = current.duration
            if (playbackState == Player.STATE_ENDED && playingKind == MessageAttachment.Kind.Audio) {
                current.seekTo(0L)
                current.pause()
                positionMillis = 0L
                isActive = false
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            val failedKey = playing
            exo?.stop()
            playing = null
            playingKind = null
            isActive = false
            positionMillis = 0L
            errorKey = failedKey
            errorMessage = "Couldn’t play this media."
        }
    }

    fun fileFor(key: String): File? = files[key]?.takeIf { it.exists() }

    suspend fun download(attachment: MessageAttachment): File? {
        val key = attachment.source.toJson()
        fileFor(key)?.let { return it }
        return try {
            loadFile(attachment)?.also { files[key] = it }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }

    suspend fun start(attachment: MessageAttachment) {
        val key = attachment.source.toJson()
        // Deduplicate taps while the same clip is already downloading.
        if (fetching == key) return
        errorKey = null
        errorMessage = null
        fetching = key
        val file = try {
            fileFor(key) ?: loadFile(attachment)?.also { files[key] = it }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        } finally {
            if (fetching == key) fetching = null
        }
        // Another clip asked for meanwhile wins; one that can't be fetched surfaces a clean retryable state.
        if (file == null) {
            errorKey = key
            errorMessage = "Couldn’t download ${attachment.name}."
            return
        }
        val instance = exo ?: ExoPlayer.Builder(context)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                    .build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            .build()
            .also {
                it.addListener(listener)
                exo = it
            }
        positionMillis = 0L
        durationMillis = attachment.durationMillis ?: 0L
        instance.run {
            setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
            prepare()
            playWhenReady = true
        }
        playing = key
        playingKind = attachment.kind
        isActive = true
    }

    suspend fun toggleAudio(attachment: MessageAttachment) {
        val key = attachment.source.toJson()
        val instance = exo
        if (playing == key && playingKind == MessageAttachment.Kind.Audio && instance != null) {
            if (instance.isPlaying) {
                instance.pause()
                isActive = false
            } else {
                if (instance.playbackState == Player.STATE_ENDED) instance.seekTo(0L)
                instance.play()
                isActive = true
            }
            return
        }
        start(attachment)
    }

    fun seekAudio(key: String, fraction: Float) {
        val instance = exo ?: return
        if (playing != key || playingKind != MessageAttachment.Kind.Audio) return
        val total = instance.duration.takeIf { it > 0L } ?: durationMillis
        if (total <= 0L) return
        val target = (total * fraction.coerceIn(0f, 1f)).toLong()
        instance.seekTo(target)
        positionMillis = target
    }

    fun syncProgress() {
        val instance = exo ?: return
        if (playingKind != MessageAttachment.Kind.Audio) return
        val pos = instance.currentPosition.coerceAtLeast(0L)
        positionMillis = pos
        if (instance.duration > 0L) durationMillis = instance.duration
    }

    fun stop(key: String) {
        if (playing != key) return
        exo?.stop()
        playing = null
        playingKind = null
        isActive = false
        positionMillis = 0L
    }

    fun pause() {
        exo?.pause()
        isActive = false
    }

    fun release() {
        exo?.removeListener(listener)
        exo?.release()
        exo = null
        playing = null
        playingKind = null
        fetching = null
        isActive = false
        positionMillis = 0L
        durationMillis = 0L
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
    LaunchedEffect(playback.playing, playback.playingKind, playback.isActive) {
        while (playback.playingKind == MessageAttachment.Kind.Audio && playback.isActive) {
            playback.syncProgress()
            delay(150L)
        }
    }
    return playback
}

/**
 * A video in its message, in the box its event's size reserves: the sender's poster with its length, then a tap plays
 * it in place (using a TextureView so rounded corners clip cleanly), and a tap while it plays opens it full screen.
 */
@Composable
internal fun InlineVideo(attachment: MessageAttachment, load: PictureLoader, videos: VideoPlayback, onLongPress: () -> Unit) {
    val colors = SlatrixTheme.colors
    val shape = MaterialTheme.shapes.large
    val scope = rememberCoroutineScope()
    val key = attachment.source.toJson()
    val player = videos.player.takeIf { videos.playing == key }
    // Remember full-screen mode across rotation; reload the clip if the activity recreated.
    var full by rememberSaveable(key) { mutableStateOf(false) }
    LaunchedEffect(full, player) {
        if (full && player == null) videos.start(attachment)
    }
    // A video scrolled away stops, as its row is gone, unless currently open full screen.
    DisposableEffect(videos, key) { onDispose { if (!full) videos.stop(key) } }
    BoxWithConstraints {
        val (width, height) = box(attachment.width, attachment.height, maxWidth, UiMetrics.MediaMaxHeight)
        val pixels = with(LocalDensity.current) { width.roundToPx() to height.roundToPx() }
        val poster = picture(attachment, pixels.first, pixels.second, false, load)
        Box(Modifier.size(width, height).clip(shape).background(colors.sunken)) {
            if (player != null && !full) {
                AndroidView(
                    factory = { ctx ->
                        LayoutInflater.from(ctx)
                            .inflate(R.layout.inline_player_view, FrameLayout(ctx), false) as PlayerView
                    },
                    modifier = Modifier.fillMaxSize(),
                    update = { it.player = player },
                    onRelease = { it.player = null },
                )
            } else {
                poster?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop) }
            }
            if (player == null) {
                Box(Modifier.align(Alignment.Center).size(UiMetrics.Touch).background(colors.mediaShade, CircleShape),
                    contentAlignment = Alignment.Center) {
                    if (videos.fetching == key) DelayedSpinner() else Icon(Icons.Filled.PlayArrow, null, tint = colors.onMedia)
                }
                if (videos.errorKey == key && videos.errorMessage != null) {
                    Text(videos.errorMessage.orEmpty(), Modifier.align(Alignment.TopCenter).padding(UiMetrics.GapSmall)
                        .background(colors.mediaShade, MaterialTheme.shapes.small)
                        .padding(horizontal = UiMetrics.GapSmall, vertical = UiMetrics.GapTiny),
                        style = MaterialTheme.typography.labelSmall, color = colors.onMedia, maxLines = 1,
                        overflow = TextOverflow.Ellipsis)
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
    player?.takeIf { full }?.let { VideoViewer(attachment, it, videos) { full = false } }
}

/** An inline audio or voice message player with play/pause, interactive waveform or scrubber, and fallback to external app. */
@Composable
internal fun InlineAudio(
    attachment: MessageAttachment,
    videos: VideoPlayback,
    onLongPress: () -> Unit,
    onOpenFile: () -> Unit,
) {
    val colors = SlatrixTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val key = attachment.source.toJson()
    val isCurrent = videos.playing == key && videos.playingKind == MessageAttachment.Kind.Audio
    val isPlaying = isCurrent && videos.isActive
    val isFetching = videos.fetching == key
    val totalMillis = if (isCurrent && videos.durationMillis > 0L) videos.durationMillis else (attachment.durationMillis ?: 0L)
    val currentMillis = if (isCurrent) videos.positionMillis else 0L
    val progress = if (totalMillis > 0L) (currentMillis.toFloat() / totalMillis.toFloat()).coerceIn(0f, 1f) else 0f
    val error = videos.errorMessage.takeIf { videos.errorKey == key }
    val title = remember(attachment) {
        if (attachment.isVoice) {
            val base = attachment.name.substringBeforeLast('.').lowercase()
            if (base.isEmpty() || base == "voice" || base == "audio" || base == "voice-message") "Voice message"
            else attachment.name
        } else attachment.name
    }
    val subtitle = remember(isCurrent, currentMillis, totalMillis, attachment.size, attachment.name, attachment.mimeType) {
        when {
            isCurrent && totalMillis > 0L -> "${durationLabel(currentMillis)} / ${durationLabel(totalMillis)}"
            else -> listOfNotNull(
                totalMillis.takeIf { it > 0L }?.let(::durationLabel),
                attachment.size?.let { Formatter.formatShortFileSize(context, it) },
            ).ifEmpty { listOf(FileKind.of(attachment.name, attachment.mimeType).label(attachment.name)) }
                .joinToString(" · ")
        }
    }
    val shape = MaterialTheme.shapes.large
    Row(
        Modifier.widthIn(min = UiMetrics.AudioCardMinWidth).clip(shape)
            .combinedClickable(
                onClickLabel = if (isPlaying) "Pause audio" else "Play audio",
                onLongClickLabel = "Message actions",
                onLongClick = onLongPress,
            ) {
                if (error != null) onOpenFile() else scope.launch { videos.toggleAudio(attachment) }
            }
            .padding(vertical = UiMetrics.GapTiny),
        horizontalArrangement = Arrangement.spacedBy(UiMetrics.GapMedium),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(UiMetrics.FileTile).clip(CircleShape).background(colors.accentFill)
                .semantics { contentDescription = if (isPlaying) "Pause audio" else "Play audio" },
            contentAlignment = Alignment.Center,
        ) {
            if (isFetching) {
                DelayedSpinner()
            } else {
                Icon(
                    if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = null,
                    modifier = Modifier.size(UiMetrics.Icon),
                    tint = colors.onAccent,
                )
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(UiMetrics.GapTiny)) {
            Text(
                title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            AudioScrubber(
                waveform = attachment.waveform,
                progress = progress,
                active = isCurrent,
                onSeek = { fraction ->
                    if (isCurrent) videos.seekAudio(key, fraction)
                    else scope.launch { videos.toggleAudio(attachment) }
                },
            )
            Text(
                error ?: subtitle,
                style = MaterialTheme.typography.labelMedium,
                color = if (error != null) colors.destructive else colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun AudioScrubber(
    waveform: List<Int>,
    progress: Float,
    active: Boolean,
    onSeek: (Float) -> Unit,
) {
    val colors = SlatrixTheme.colors
    val bars = remember(waveform) {
        if (waveform.isEmpty()) emptyList()
        else {
            val count = 28
            val maxSample = maxOf(waveform.maxOrNull() ?: 1, 1).toFloat()
            List(count) { idx ->
                val start = idx * waveform.size / count
                val end = maxOf(start + 1, (idx + 1) * waveform.size / count)
                val peak = waveform.subList(start, minOf(end, waveform.size)).maxOrNull() ?: 0
                (peak / maxSample).coerceIn(0.18f, 1f)
            }
        }
    }
    Box(
        Modifier.fillMaxWidth()
            .height(if (bars.isNotEmpty()) UiMetrics.AudioWaveformHeight else UiMetrics.GapMedium)
            .pointerInput(onSeek) {
                detectTapGestures { offset ->
                    val fraction = if (size.width > 0) (offset.x / size.width).coerceIn(0f, 1f) else 0f
                    onSeek(fraction)
                }
            },
        contentAlignment = Alignment.CenterStart,
    ) {
        if (bars.isNotEmpty()) {
            Row(
                Modifier.fillMaxSize(),
                horizontalArrangement = Arrangement.spacedBy(UiMetrics.LineGap),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                bars.forEachIndexed { idx, amp ->
                    val filled = active && (idx + 1).toFloat() / bars.size <= progress
                    Box(
                        Modifier.weight(1f).fillMaxHeight(amp).clip(CircleShape)
                            .background(if (filled) colors.accent else colors.border)
                    )
                }
            }
        } else {
            Box(Modifier.fillMaxWidth().height(UiMetrics.AudioTrackHeight).clip(CircleShape).background(colors.sunken)) {
                if (active && progress > 0f) {
                    Box(Modifier.fillMaxWidth(progress).fillMaxHeight().clip(CircleShape).background(colors.accent))
                }
            }
        }
    }
}

@Composable
private fun DelayedSpinner() {
    var late by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { delay(UiMetrics.ProgressDelayMillis); late = true }
    if (late) CircularProgressIndicator(Modifier.size(UiMetrics.Icon), color = SlatrixTheme.colors.onMedia)
}

/** A video full screen on black with the player's controls, Share and Save, carrying on from where it played in the row. */
@Composable
private fun VideoViewer(attachment: MessageAttachment, player: Player, videos: VideoPlayback, onDismiss: () -> Unit) {
    val colors = SlatrixTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var notice by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(notice) { if (notice != null) { delay(UiMetrics.NoticeMillis); notice = null } }
    fun withFile(action: suspend (File) -> String?) {
        scope.launch {
            val file = videos.download(attachment)
            notice = if (file == null) "Couldn’t download ${attachment.name}." else try {
                action(file)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                "Couldn’t save ${attachment.name}."
            }
        }
    }
    Dialog(onDismiss, DialogProperties(usePlatformDefaultWidth = false)) {
        Box(Modifier.fillMaxSize().background(colors.mediaBackdrop)) {
            AndroidView({ PlayerView(it) }, Modifier.fillMaxSize(), update = { it.player = player }, onRelease = { it.player = null })
            Row(Modifier.fillMaxWidth().statusBarsPadding().background(colors.mediaShade).padding(end = UiMetrics.GapSmall),
                verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onDismiss) { Icon(Icons.Outlined.Close, "Close", tint = colors.onMedia) }
                Text(attachment.name, Modifier.weight(1f), style = MaterialTheme.typography.titleSmall, color = colors.onMedia,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                IconButton(onClick = { withFile { shareFile(context, it, attachment); null } }) {
                    Icon(Icons.Outlined.Share, "Share", tint = colors.onMedia)
                }
                IconButton(onClick = { withFile { saveFile(context, it, attachment) } }) {
                    Icon(Icons.Outlined.FileDownload, "Save to device", tint = colors.onMedia)
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
