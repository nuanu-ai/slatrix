package ai.nuanu.slatrix.ui.account

import ai.nuanu.slatrix.core.MatrixLink
import ai.nuanu.slatrix.core.MatrixLinks
import ai.nuanu.slatrix.core.RoomSummary
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.UriHandler
import kotlinx.coroutines.launch

/**
 * Opens Matrix links in [content] inside the app, as the Mac does: a conversation you're in, or a message in one,
 * [onOpen]s there. Other links, and conversations you're not in, go on to the browser; a malformed Matrix link says so.
 */
@Composable
fun ProvideMatrixLinks(rooms: List<RoomSummary>, resolveAlias: suspend (String) -> String?,
    onOpen: (RoomSummary, eventId: String?) -> Unit, onNotice: (String) -> Unit, content: @Composable () -> Unit) {
    val outer = LocalUriHandler.current
    val scope = rememberCoroutineScope()
    val joined by rememberUpdatedState(rooms)
    val resolve by rememberUpdatedState(resolveAlias)
    val open by rememberUpdatedState(onOpen)
    val notice by rememberUpdatedState(onNotice)
    val handler = remember(outer, scope) {
        object : UriHandler {
            override fun openUri(uri: String) {
                if (!MatrixLinks.isMatrix(uri)) return outer.openUri(uri)
                val link = MatrixLinks.parse(uri) ?: return notice("Slatrix can’t open this link.")
                fun show(roomId: String?, event: String?) = joined.firstOrNull { it.id == roomId }?.let { open(it, event) } ?: outer.openUri(uri)
                when (val target = link.target) {
                    // shortcut: people open in the browser, until the app shows their profiles.
                    is MatrixLink.Target.User -> outer.openUri(uri)
                    is MatrixLink.Target.Room -> show(target.id, target.event)
                    is MatrixLink.Target.Alias -> scope.launch { show(resolve(target.alias), target.event) }
                }
            }
        }
    }
    CompositionLocalProvider(LocalUriHandler provides handler, content = content)
}
