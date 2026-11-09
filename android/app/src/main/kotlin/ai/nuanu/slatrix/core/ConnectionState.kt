package ai.nuanu.slatrix.core

import java.util.logging.Logger

internal val connectionLog: Logger = Logger.getLogger("SlatrixConnection")

enum class ConnectionState(val label: String) {
    Connecting("Connecting…"), Connected("Connected"), Offline("You’re offline"), Reconnecting("Reconnecting…"), Paused("Paused");

    companion object {
        fun resolve(network: Boolean?, foreground: Boolean, running: Boolean, responded: Boolean,
            interrupted: Boolean, previouslyConnected: Boolean): ConnectionState = when {
            !foreground -> Paused
            network == false -> Offline
            running && responded -> Connected
            interrupted || previouslyConnected -> Reconnecting
            else -> Connecting
        }
    }
}
