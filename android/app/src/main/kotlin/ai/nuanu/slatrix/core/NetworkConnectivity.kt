package ai.nuanu.slatrix.core

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow

data class NetworkStatus(val available: Boolean, val routeChanged: Boolean = false)

internal fun networkAvailability(context: Context): Flow<NetworkStatus> = callbackFlow {
    val connectivity = context.getSystemService(ConnectivityManager::class.java)
    val lock = Any()
    var current: Network? = null
    var heardCallback = false
    val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = synchronized(lock) {
            heardCallback = true
            val changed = current != null && current != network
            current = network
            trySend(NetworkStatus(true, routeChanged = changed))
            Unit
        }
        override fun onLost(network: Network) = synchronized(lock) {
            heardCallback = true
            if (current == network) {
                current = null
                trySend(NetworkStatus(false))
            }
        }
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            synchronized(lock) {
                if (current == network && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) trySend(NetworkStatus(true))
            }
        }
    }
    connectivity.registerDefaultNetworkCallback(callback)
    // The initial snapshot must not overwrite a newer callback, and a phone with no network gets no onAvailable.
    synchronized(lock) {
        if (!heardCallback) {
            current = connectivity.activeNetwork
            trySend(NetworkStatus(current != null))
        }
    }
    awaitClose { connectivity.unregisterNetworkCallback(callback) }
}
