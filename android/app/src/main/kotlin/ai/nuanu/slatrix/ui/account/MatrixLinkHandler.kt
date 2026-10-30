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
 * [onOpen]s there, and a person's profile opens. Other links, and conversations you're not in, go on to the browser; a
 * malformed Matrix link says so.
 */
@Composable
fun ProvideMatrixLinks(rooms: () -> List<RoomSummary>, resolveAlias: suspend (String) -> String?,
    onOpen: (RoomSummary, eventId: String?) -> Unit, onPerson: (userId: String) -> Unit, onNotice: (String) -> Unit,
    content: @Composable () -> Unit) {
    val outer = LocalUriHandler.current
    val scope = rememberCoroutineScope()
    // Read only when a link opens, so the room list's updates never recompose the conversation.
    val joined by rememberUpdatedState(rooms)
    val resolve by rememberUpdatedState(resolveAlias)
    val open by rememberUpdatedState(onOpen)
    val person by rememberUpdatedState(onPerson)
    val notice by rememberUpdatedState(onNotice)
    val handler = remember(outer, scope) {
        object : UriHandler {
            override fun openUri(uri: String) {
                if (!MatrixLinks.isMatrix(uri)) return outer.openUri(uri)
                val link = MatrixLinks.parse(uri) ?: return notice("Slatrix can’t open this link.")
                // A browser can't open a matrix: URI, so it gets the matrix.to link.
                fun browse() = outer.openUri(if (uri.startsWith("https:")) uri else link.web)
                fun show(roomId: String?, event: String?) = joined().firstOrNull { it.id == roomId }?.let { open(it, event) } ?: browse()
                when (val target = link.target) {
                    is MatrixLink.Target.User -> person(target.id)
                    is MatrixLink.Target.Room -> show(target.id, target.event)
                    is MatrixLink.Target.Alias -> scope.launch { show(resolve(target.alias), target.event) }
                }
            }
        }
    }
    CompositionLocalProvider(LocalUriHandler provides handler, content = content)
}
