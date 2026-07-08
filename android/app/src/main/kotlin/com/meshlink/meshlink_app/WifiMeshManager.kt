package com.meshlink.meshlink_app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Phase 6 WiFi mesh join — Android side of the `meshlink/wifi_mesh` channel
 * (lib/transport/wifi/android_wifi_join.dart).
 *
 * Uses WifiNetworkSpecifier so the mesh network is scoped to this app's own
 * traffic: the request deliberately omits NET_CAPABILITY_INTERNET, so the OS
 * never runs its captive-portal probe against the internet-less mesh, never
 * shows the generic "no internet" warning, and never displaces cellular as
 * the phone's default route (WiFi Mesh Add-On §3.2). The one-time system
 * confirmation is remembered; later joins to the same SSID are silent.
 *
 * While joined, the process is bound to the mesh network so Dart's plain
 * sockets reach the node at 10.78.0.x (an app-scoped network is otherwise
 * invisible to the default route). leave() unbinds and releases the request.
 */
class WifiMeshManager(private val context: Context) {

    companion object {
        private const val TAG = "WifiMeshManager"
        private const val CHANNEL = "meshlink/wifi_mesh"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var network: Network? = null

    private val connectivity: ConnectivityManager
        get() = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "currentState" -> result.success(currentState())
                    "join" -> join(
                        call.argument<String>("ssid")!!,
                        call.argument<String>("passphrase")!!,
                        result,
                    )
                    "leave" -> {
                        leave()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    /** Pre-join state for the toggle's tradeoff warning. WiFi Calling state
     * has no public query API, so it is reported as unknown (null). */
    private fun currentState(): Map<String, Any?> {
        val wifi = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val ssid = wifi.connectionInfo?.ssid
            ?.removeSurrounding("\"")
            ?.takeUnless { it.isEmpty() || it == "<unknown ssid>" }
        return mapOf("currentSsid" to ssid, "wifiCallingActive" to null)
    }

    private fun join(ssid: String, passphrase: String, result: MethodChannel.Result) {
        if (network != null) {
            result.success(null) // already joined
            return
        }
        leave() // drop any half-finished previous request

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(passphrase)
            .build()
        // No NET_CAPABILITY_INTERNET: the mesh is internet-less by design,
        // and requesting it would make this request never match.
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        var settled = false
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(net: Network) {
                mainHandler.post {
                    network = net
                    connectivity.bindProcessToNetwork(net)
                    Log.i(TAG, "mesh network available, process bound")
                    if (!settled) {
                        settled = true
                        result.success(null)
                    }
                }
            }

            override fun onUnavailable() {
                mainHandler.post {
                    Log.w(TAG, "mesh network unavailable (declined or not found)")
                    leave()
                    if (!settled) {
                        settled = true
                        result.error("unavailable",
                            "Mesh network not found or join was declined", null)
                    }
                }
            }

            override fun onLost(net: Network) {
                mainHandler.post {
                    Log.w(TAG, "mesh network lost")
                    network = null
                    connectivity.bindProcessToNetwork(null)
                    channel?.invokeMethod("onLost", null)
                }
            }
        }
        callback = cb
        connectivity.requestNetwork(request, cb)
    }

    private fun leave() {
        callback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (_: IllegalArgumentException) {
                // already unregistered
            }
        }
        callback = null
        network = null
        connectivity.bindProcessToNetwork(null)
    }
}
